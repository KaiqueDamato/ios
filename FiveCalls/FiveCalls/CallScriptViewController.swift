//
//  CallScriptViewController.swift
//  FiveCalls
//
//  Created by Patrick McCarron on 2/3/17.
//

import UIKit
import CoreLocation
import StoreKit
import OneSignal
import Kingfisher
import Down

class CallScriptViewController : UIViewController, IssueShareable {
    
    var issuesManager: IssuesManager!
    var issue: Issue!
    var contactIndex = 0
    var contact: Contact!
    var contacts: [Contact]!
    var logs = ContactLogs.load()
    var lastPhoneDialed: String?
    
    var isLastContactForIssue: Bool {
        let contactIndex = contacts.index(of: contact)
        return contactIndex == contacts.count - 1
    }

    lazy var ratingPromptCounter: RatingPromptCounter = {
        let handler: (() -> Void)?
        if #available(iOS 10.3, *) {
            handler = { SKStoreReviewController.requestReview() }
        } else {
            handler = nil
        }

        return RatingPromptCounter(handler: handler)
    }()
    
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var resultInstructionsLabel: UILabel!
    @IBOutlet weak var outcomesCollection: UICollectionView!
    @IBOutlet weak var footerHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var progressView: ProgressView!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(CallScriptViewController.shareButtonPressed(_ :)))
        
        tableView.estimatedRowHeight = 100
        tableView.rowHeight = UITableView.automaticDimension
        if self.presentingViewController != nil {
            self.navigationItem.leftBarButtonItem = self.iPadDoneButton
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let issue = issue, let contactIndex = contacts.index(of: contact) else {
            return assertionFailure("no issue or contact in call script")
        }
        
        AnalyticsManager.shared.trackEvent(withName: "Action: Issue Call Script", andProperties: ["issue_id": String(issue.id)])
        self.contactIndex = contactIndex
        let contactsCount = contacts.count
        title = "Contact \(contactIndex+1) of \(contactsCount)"

        // set the footer height based on how many outcomes there are:
        // cell height (+ padding) + extra footer spacing
        footerHeightConstraint.constant = (ceil(CGFloat(issue.outcomeModels.count) / 2) * OutcomeCollectionCell.cellHeight() + 10) + 40
    }
    
    func back() {
        _ = navigationController?.popViewController(animated: true)
    }
    
    @objc func dismissCallScript() {
        self.dismiss(animated: true, completion: nil)
    }
    
    var iPadDoneButton: UIBarButtonItem {
        return UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissCallScript))
    }
    
    @objc func callButtonPressed(_ button: UIButton) {
        AnalyticsManager.shared.trackEvent(withName:"Action: Dialed Number", andProperties: ["contact_id":contact.id])
        callNumber(contact.phone)
    }

    fileprivate func callNumber(_ number: String) {
        
        self.lastPhoneDialed = number
        
        let defaults = UserDefaults.standard
        let firstCallInstructionsKey =  UserDefaultsKey.hasSeenFirstCallInstructions.rawValue
        
        let callErrorCompletion: (Bool) -> Void = { [weak self] successful in
            if !successful {
                DispatchQueue.main.async {
                    self?.showCallFailedAlert()
                }
            }
        }
        
        if defaults.bool(forKey: firstCallInstructionsKey) {
            guard let dialURL = URL(string: "telprompt:\(number)") else { return }
            UIApplication.shared.open(dialURL, completionHandler: callErrorCompletion)
        } else {
            let alertController = UIAlertController(title: R.string.localizable.firstCallAlertTitle(),
                                                    message:  R.string.localizable.firstCallAlertMessage(),
                                                    preferredStyle: .alert)
            
            let cancelAction = UIAlertAction(title: R.string.localizable.cancelButtonTitle(),
                                             style: .cancel) { _ in
                                                alertController.dismiss(animated: true, completion: nil)
            }
            
            let callAction = UIAlertAction(title: R.string.localizable.firstCallAlertCall(),
                                             style: .default) { _ in
                                                alertController.dismiss(animated: true, completion: nil)
                                                guard let dialURL = URL(string: "tel:\(number)") else { return }
                                                UIApplication.shared.open(dialURL, completionHandler: callErrorCompletion)
                                                
                                                defaults.set(true, forKey: firstCallInstructionsKey)
            }
            
            alertController.addAction(cancelAction)
            alertController.addAction(callAction)
            
            present(alertController, animated: true, completion: nil)
        }
    }
    
    func reportCallOutcome(log: ContactLog, outcome: Outcome) {
        logs.add(log: log)
        let operation = ReportOutcomeOperation(log: log, outcome: outcome)
        OperationQueue.main.addOperation(operation)
    }
    
    func hideResultButtons(animated: Bool) {
        let duration = animated ? 0.5 : 0
        let hideDuration = duration * 0.6
        UIView.animate(withDuration: hideDuration) {
            self.outcomesCollection.alpha = 0
            self.resultInstructionsLabel.alpha = 0
        }

        progressView.alpha = 0
        progressView.transform = progressView.transform.scaledBy(x: 0.2, y: 0.2)
        progressView.isHidden = false
        
        UIView.animate(withDuration: duration, delay: duration * 0.75, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
            self.progressView.alpha = 1
            self.progressView.transform = .identity
        }, completion: nil)
    }
    
    func handleCallOutcome(outcome: Outcome) {
        // save & send log entry
        let contactedPhone = lastPhoneDialed ?? contact.phone
        // ContactLog status is "contacted", "unavailable", "vm", same for every issue
        // whereas outcome can be anything passed by the server
        let log = ContactLog(issueId: String(issue.id), contactId: contact.id, phone: contactedPhone, outcome: outcome.status, date: Date(), reported: false)
        reportCallOutcome(log: log, outcome: outcome)
    }

    func showNextContact(_ contact: Contact) {
        let newController = R.storyboard.main.callScriptController()!
        newController.issuesManager = issuesManager
        newController.issue = issue
        newController.contact = contact
        newController.contacts = contacts
        navigationController?.replaceTopViewController(with: newController, animated: true)
    }
    
    @objc func shareButtonPressed(_ button: UIBarButtonItem) {
        shareIssue(from: button)
    }
        
    private func showCallFailedAlert() {
        let alertController = UIAlertController(title: R.string.localizable.placeCallFailedTitle(),
                                                message:  R.string.localizable.placeCallFailedMessage(),
                                                preferredStyle: .alert)
        
        let okAction = UIAlertAction(title: R.string.localizable.okButtonTitle(),
                                     style: .default) { _ in
                                        alertController.dismiss(animated: true, completion: nil)
        }
        
        alertController.addAction(okAction)
        
        present(alertController, animated: true, completion: nil)
    }

    func checkForNotifications() {
        let permissions = OneSignal.getPermissionSubscriptionState()
        let nextPrompt = nextNotificationPromptDate() ?? Date()
        
        if permissions?.permissionStatus.hasPrompted == false && nextPrompt <= Date() {
            let alert = UIAlertController(title: R.string.localizable.notificationTitle(), message: R.string.localizable.notificationAsk(), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: R.string.localizable.notificationAll(), style: .default, handler: { (action) in
                OneSignal.promptForPushNotifications(userResponse: { (success) in
                    OneSignal.sendTag("all", value: "true")
                })
            }))
            alert.addAction(UIAlertAction(title: R.string.localizable.notificationImportant(), style: .default, handler: { (action) in
                OneSignal.promptForPushNotifications(userResponse: { (success) in
                    //
                })
            }))
            alert.addAction(UIAlertAction(title: R.string.localizable.notificationNone(), style: .cancel, handler: { (action) in
                let key = UserDefaultsKey.lastAskedForNotificationPermission.rawValue
                UserDefaults.standard.set(Date(), forKey: key)
            }))
            present(alert, animated: true, completion: nil)
        }
    }
    
    func nextNotificationPromptDate() -> Date? {
        let key = UserDefaultsKey.lastAskedForNotificationPermission.rawValue
        guard let lastPrompt = UserDefaults.standard.object(forKey: key) as? Date else { return nil }
        
        return Calendar.current.date(byAdding: .month, value: 1, to: lastPrompt)
    }
}

enum CallScriptRows : Int {
    case contact
    case script
    case count
}

extension CallScriptViewController : UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return CallScriptRows.count.rawValue
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.row {
        
        case CallScriptRows.contact.rawValue:
            let cell = tableView.dequeueReusableCell(withIdentifier: R.reuseIdentifier.contactDetailCell, for: indexPath)!
            cell.callButton.setTitle("☎️ " + contact.phone, for: .normal)
            cell.callButton.addTarget(self, action: #selector(callButtonPressed(_:)), for: .touchUpInside)
            cell.nameLabel.text = contact.name
            cell.callingReasonLabel.text = contact.reason
            if let photoURL = contact.photoURL {
                cell.avatarImageView.kf.setImage(with: photoURL)
            } else {
                cell.avatarImageView.image = UIImage(named: "icon-office")
            }
            
            cell.moreNumbersButton.isHidden = contact.fieldOffices.isEmpty
            cell.moreNumbersButton.addTarget(self, action: #selector(CallScriptViewController.moreNumbersTapped), for: .touchUpInside)
            // This helps both resizing labels we have actually display correctly 
            cell.layoutIfNeeded()
            return cell
            
        case CallScriptRows.script.rawValue:
            let cell = tableView.dequeueReusableCell(withIdentifier: R.reuseIdentifier.scriptCell, for: indexPath)!

            let markdown = Down.init(markdownString: issue.script)
            if let converted = try? markdown.toAttributedString(.default, stylesheet: Issue.style) {
                cell.scriptTextView.attributedText = converted
            } else {
                cell.scriptTextView.text = issue.script
            }

            return cell
            
        default:
            return UITableViewCell()
            
        }
    }
    
    @objc func moreNumbersTapped() {
        AnalyticsManager.shared.trackEvent(withName: "Action: Opened More Numbers", andProperties: ["contact_id":contact.id])
        if contact.fieldOffices.count > 0 {
            let contactID = contact.id
            let sheet = UIAlertController(title: R.string.localizable.chooseANumber(), message: nil, preferredStyle: .actionSheet)
            for office in contact.fieldOffices {
                let title = office.city.isEmpty ? "\(office.phone)" : "\(office.city): \(office.phone)"
                sheet.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] action in
                    AnalyticsManager.shared.trackEvent(withName: "Action: Dialed Alternate Number", andProperties: ["contact_id":contactID])
                    self?.callNumber(office.phone)
                }))
            }
            sheet.addAction(UIAlertAction(title: R.string.localizable.cancelButtonTitle(), style: .cancel, handler: { [weak self] action in
                self?.dismiss(animated: true, completion: nil)
            }))
            self.present(sheet, animated: true, completion: nil)
        }
    }
}

extension CallScriptViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return issue.outcomeModels.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: R.reuseIdentifier.outcomeCell, for: indexPath)!

        let outcomeModel = issue.outcomeModels[indexPath.row]
        let outcomeStringKey = "outcomes.\(outcomeModel.label)"
        var localizedOutcome = NSLocalizedString(outcomeStringKey, comment: "The outcome button title describing the outcome '\(outcomeModel.label)'")

        // if we can't schedule a release to translate a new outcome in time, just use a capitalized version of the outcome key
        if localizedOutcome == outcomeStringKey {
            localizedOutcome = outcomeModel.label.capitalized
        }
        cell.outcomeLabel.text = localizedOutcome

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let outcomeModel = issue.outcomeModels[indexPath.row]

        AnalyticsManager.shared.trackEvent(withName: "Action: Button \(outcomeModel.label)", andProperties: ["contact_id":contact.id])

        if outcomeModel.label != "skip" {
            handleCallOutcome(outcome: outcomeModel)
        }

        if isLastContactForIssue {
            hideResultButtons(animated: true)

            // these two should never show at the same time, rating will always
            // wait until 5, notifications will trigger on the first one.
            ratingPromptCounter.increment()
            checkForNotifications()
        } else {
            let nextContact = contacts[contactIndex + 1]
            showNextContact(nextContact)
        }

    }
}

extension CallScriptViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {

        // this width calculation kinda sucks
        // screenwidth, minus two 8pt sides and a 10pt min middle cell space
        let width = ((view.bounds.width - 8 - 8) - 10) / 2

        return CGSize(width: width, height: OutcomeCollectionCell.cellHeight())
    }
}
