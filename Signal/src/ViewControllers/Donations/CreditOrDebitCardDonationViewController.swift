//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalMessaging
import AuthenticationServices

class CreditOrDebitCardDonationViewController: OWSTableViewController2 {
    let donationAmount: FiatMoney
    let donationMode: DonationMode
    let onFinished: () -> Void
    var threeDSecureAuthenticationSession: ASWebAuthenticationSession?

    init(
        donationAmount: FiatMoney,
        donationMode: DonationMode,
        onFinished: @escaping () -> Void
    ) {
        owsAssert(FeatureFlags.canDonateWithCard)

        self.donationAmount = donationAmount
        self.donationMode = donationMode
        self.onFinished = onFinished

        super.init()
    }

    deinit {
        threeDSecureAuthenticationSession?.cancel()
    }

    // MARK: - View callbacks

    public override func viewDidLoad() {
        shouldAvoidKeyboard = true

        super.viewDidLoad()

        render()

        contents = OWSTableContents(sections: [
            donationAmountSection,
            cardNumberSection,
            expirationDateSection,
            cvvSection,
            submitButtonSection
        ])
    }

    public override func themeDidChange() {
        super.themeDidChange()

        render()
    }

    // MARK: - Events

    private func didSubmit() {
        switch formState {
        case .invalid, .potentiallyValid:
            owsFail("It should be impossible to submit the form without a fully-valid card. Is the submit button properly disabled?")
        case let .fullyValid(creditOrDebitCard):
            switch donationMode {
            case .oneTime:
                oneTimeDonation(with: creditOrDebitCard)
            case let .monthly(
                subscriptionLevel,
                subscriberID,
                _,
                currentSubscriptionLevel
            ):
                monthlyDonation(
                    with: creditOrDebitCard,
                    newSubscriptionLevel: subscriptionLevel,
                    priorSubscriptionLevel: currentSubscriptionLevel,
                    subscriberID: subscriberID
                )
            }
        }
    }

    func didFailDonation(error: Error) {
        DonationViewsUtil.presentDonationErrorSheet(
            from: self,
            error: error,
            currentSubscription: {
                switch donationMode {
                case .oneTime: return nil
                case let .monthly(_, _, currentSubscription, _): return currentSubscription
                }
            }()
        )
    }

    // MARK: - Rendering

    private func render() {
        // We'd like a link that doesn't go anywhere, because we'd like to
        // handle the tapping ourselves. We use a "fake" URL because BonMot
        // needs one.
        let linkPart = StringStyle.Part.link(SupportConstants.subscriptionFAQURL)

        subheaderTextView.attributedText = .composed(of: [
            NSLocalizedString(
                "CARD_DONATION_SUBHEADER_TEXT",
                comment: "On the credit/debit card donation screen, a small amount of information text is shown. This is that text. It should (1) instruct users to enter their credit/debit card information (2) tell them that Signal does not collect or store their personal information."
            ),
            " ",
            NSLocalizedString(
                "CARD_DONATION_SUBHEADER_LEARN_MORE",
                comment: "On the credit/debit card donation screen, a small amount of information text is shown. Users can click this link to learn more information."
            ).styled(with: linkPart)
        ]).styled(with: .color(Theme.primaryTextColor), .font(.ows_dynamicTypeBody))
        subheaderTextView.linkTextAttributes = [
            .foregroundColor: Theme.accentBlueColor,
            .underlineColor: UIColor.clear,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        subheaderTextView.textAlignment = .center

        // Only change the placeholder when enough digits are entered.
        // Helps avoid a jittery UI as you type/delete.
        let rawNumber = cardNumberTextField.text ?? ""
        if rawNumber.count >= 2 {
            let cardType = CreditAndDebitCards.cardType(ofNumber: rawNumber)
            cvvTextField.placeholder = String("1234".prefix(cardType.cvvCount))
        }

        switch formState {
        case .invalid, .potentiallyValid:
            submitButton.isEnabled = false
        case .fullyValid:
            submitButton.isEnabled = true
        }
    }

    // MARK: - Donation amount section

    private lazy var subheaderTextView: LinkingTextView = {
        let result = LinkingTextView()
        result.delegate = self
        return result
    }()

    private lazy var donationAmountSection: OWSTableSection = {
        let result = OWSTableSection(
            items: [.init(
                customCellBlock: { [weak self] in
                    let cell = OWSTableItem.newCell()
                    cell.selectionStyle = .none

                    guard let self else { return cell }

                    let headerLabel = UILabel()
                    headerLabel.text = {
                        let amountString = DonationUtilities.format(money: self.donationAmount)
                        let format = NSLocalizedString(
                            "CARD_DONATION_HEADER",
                            comment: "Users can donate to Signal with a credit or debit card. This is the heading on that screen, telling them how much they'll donate. Embeds {{formatted amount of money}}, such as \"$20\"."
                        )
                        return String(format: format, amountString)
                    }()
                    headerLabel.font = .ows_dynamicTypeTitle3.ows_semibold
                    headerLabel.textAlignment = .center
                    headerLabel.numberOfLines = 0
                    headerLabel.lineBreakMode = .byWordWrapping

                    let stackView = UIStackView(arrangedSubviews: [
                        headerLabel,
                        self.subheaderTextView
                    ])
                    cell.contentView.addSubview(stackView)
                    stackView.axis = .vertical
                    stackView.spacing = 4
                    stackView.autoPinEdgesToSuperviewMargins()

                    return cell
                }
            )]
        )
        result.hasBackground = false
        return result
    }()

    // MARK: - Card form

    private func textField() -> UITextField {
        let result = OWSTextField()

        result.font = .ows_dynamicTypeBodyClamped
        result.textColor = Theme.primaryTextColor
        result.autocorrectionType = .no
        result.spellCheckingType = .no
        result.keyboardType = .asciiCapableNumberPad

        result.delegate = self

        return result
    }

    private var formState: FormState {
        Self.formState(
            cardNumber: cardNumberTextField.text,
            isCardNumberFieldFocused: cardNumberTextField.isFirstResponder,
            expirationDate: expirationDateTextField.text,
            cvv: cvvTextField.text
        )
    }

    // MARK: Card number

    static func formatCardNumber(unformatted: String) -> String {
        var gaps: Set<Int>
        switch CreditAndDebitCards.cardType(ofNumber: unformatted) {
        case .americanExpress: gaps = [4, 10]
        case .unionPay, .other: gaps = [4, 8, 12]
        }

        var result = [Character]()
        for (i, character) in unformatted.enumerated() {
            if gaps.contains(i) {
                result.append(" ")
            }
            result.append(character)
        }
        if gaps.contains(unformatted.count) {
            result.append(" ")
        }
        return String(result)
    }

    private lazy var cardNumberTextField: UITextField = {
        let result = textField()
        result.placeholder = "0000 0000 0000 0000"
        result.textContentType = .creditCardNumber
        result.accessibilityIdentifier = "card_number_textfield"
        return result
    }()

    private lazy var cardNumberSection: OWSTableSection = {
        OWSTableSection(
            title: NSLocalizedString(
                "CARD_DONATION_CARD_NUMBER_LABEL",
                comment: "Users can donate to Signal with a credit or debit card. This is the label for the card number field on that screen."
            ),
            items: [.init(
                customCellBlock: { [weak self] in
                    let cell = OWSTableItem.newCell()
                    cell.selectionStyle = .none

                    guard let self else { return cell }

                    cell.contentView.addSubview(self.cardNumberTextField)
                    self.cardNumberTextField.autoPinEdgesToSuperviewMargins()

                    return cell
                },
                actionBlock: { [weak self] in
                    self?.cardNumberTextField.becomeFirstResponder()
                }
            )]
        )
    }()

    // MARK: Expiration date

    static func formatExpirationDate(unformatted: String) -> String {
        switch unformatted.count {
        case 0:
            return unformatted
        case 1:
            let firstDigit = unformatted.first!
            switch firstDigit {
            case "0", "1": return unformatted
            default: return unformatted + "/"
            }
        case 2:
            if (UInt8(unformatted) ?? 0).isValidAsMonth {
                return unformatted + "/"
            } else {
                return "\(unformatted.prefix(1))/\(unformatted.suffix(1))"
            }
        default:
            let firstTwo = unformatted.prefix(2)
            let firstTwoAsMonth = UInt8(String(firstTwo)) ?? 0
            let monthCount = firstTwoAsMonth.isValidAsMonth ? 2 : 1
            let month = unformatted.prefix(monthCount)
            let year = unformatted.suffix(unformatted.count - monthCount)
            return "\(month)/\(year)"
        }
    }

    private lazy var expirationDateTextField: UITextField = {
        let result = textField()
        result.placeholder = NSLocalizedString(
            "CARD_DONATION_EXPIRATION_DATE_PLACEHOLDER",
            comment: "Users can donate to Signal with a credit or debit card. This is the label for the card expiration date field on that screen."
        )
        result.accessibilityIdentifier = "expiration_date_textfield"
        return result
    }()

    private lazy var expirationDateSection: OWSTableSection = {
        OWSTableSection(
            title: NSLocalizedString(
                "CARD_DONATION_EXPIRATION_DATE_LABEL",
                comment: "Users can donate to Signal with a credit or debit card. This is the label for the expiration date field on that screen. Try to use a short string to make space in the UI. (For example, the English text uses \"Exp. Date\" instead of \"Expiration Date\")."
            ),
            items: [.init(
                customCellBlock: { [weak self] in
                    let cell = OWSTableItem.newCell()
                    cell.selectionStyle = .none

                    guard let self else { return cell }

                    cell.contentView.addSubview(self.expirationDateTextField)
                    self.expirationDateTextField.autoPinEdgesToSuperviewMargins()

                    return cell
                },
                actionBlock: { [weak self] in
                    self?.expirationDateTextField.becomeFirstResponder()
                }
            )]
        )
    }()

    // MARK: CVV

    private lazy var cvvTextField: UITextField = {
        let result = textField()
        result.placeholder = "123"
        result.accessibilityIdentifier = "cvv_textfield"
        return result
    }()

    private lazy var cvvSection: OWSTableSection = {
        OWSTableSection(
            title: NSLocalizedString(
                "CARD_DONATION_CVV_LABEL",
                comment: "Users can donate to Signal with a credit or debit card. This is the label for the card verification code (CVV) field on that screen."
            ),
            items: [.init(
                customCellBlock: { [weak self] in
                    let cell = OWSTableItem.newCell()
                    cell.selectionStyle = .none

                    guard let self else { return cell }

                    cell.contentView.addSubview(self.cvvTextField)
                    self.cvvTextField.autoPinEdgesToSuperviewMargins()

                    return cell
                },
                actionBlock: { [weak self] in
                    self?.cvvTextField.becomeFirstResponder()
                }
            )]
        )
    }()

    // MARK: - Submit button

    private lazy var submitButton: OWSButton = {
        let title = NSLocalizedString(
            "CARD_DONATION_DONATE_BUTTON",
            comment: "Users can donate to Signal with a credit or debit card. This is the text on the \"Donate\" button."
        )
        let result = OWSButton(title: title) { [weak self] in
            self?.didSubmit()
        }
        result.dimsWhenHighlighted = true
        result.dimsWhenDisabled = true
        result.layer.cornerRadius = 8
        result.backgroundColor = .ows_accentBlue
        result.titleLabel?.font = .ows_dynamicTypeBody.ows_semibold
        return result
    }()

    private lazy var submitButtonSection: OWSTableSection = {
        let submitButton = self.submitButton

        let result = OWSTableSection(items: [.init(
            customCellBlock: {
                let cell = OWSTableItem.newCell()
                cell.selectionStyle = .none

                cell.contentView.addSubview(submitButton)
                submitButton.autoPinWidthToSuperviewMargins()
                submitButton.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)
                return cell
            }
        )])
        result.hasBackground = false
        return result
    }()
}

// MARK: - UITextViewDelegate

extension CreditOrDebitCardDonationViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        if textView == subheaderTextView {
            present(CreditOrDebitCardReadMoreSheetViewController(), animated: true)
        }
        return false
    }
}

// MARK: - UITextFieldDelegate

extension CreditOrDebitCardDonationViewController: UITextFieldDelegate {
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString: String
    ) -> Bool {
        let maxDigits: Int
        let format: (String) -> String
        switch textField {
        case cardNumberTextField:
            maxDigits = 19
            format = Self.formatCardNumber
        case expirationDateTextField:
            maxDigits = 4
            format = Self.formatExpirationDate
        case cvvTextField:
            maxDigits = 4
            format = { $0 }
        default:
            owsFail("Unexpected text field")
        }

        let result = FormattedNumberField.textField(
            textField,
            shouldChangeCharactersIn: range,
            replacementString: replacementString,
            maxDigits: maxDigits,
            format: format
        )

        render()

        return result
    }
}

fileprivate extension UInt8 {
    var isValidAsMonth: Bool { self >= 1 && self <= 12 }
}
