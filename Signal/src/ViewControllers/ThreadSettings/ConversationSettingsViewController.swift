//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import UIKit
import ContactsUI

@objc
public enum ConversationSettingsPresentationMode: UInt {
    case `default`
    case showVerification
    case showMemberRequests
    case showAllMedia
}

// MARK: -

@objc
public protocol ConversationSettingsViewDelegate: class {

    func conversationColorWasUpdated()

    func conversationSettingsDidUpdate()

    func conversationSettingsDidRequestConversationSearch()

    func popAllConversationSettingsViews(completion: (() -> Void)?)
}

// MARK: -

// TODO: We should describe which state updates & when it is committed.
@objc
class ConversationSettingsViewController: OWSTableViewController2 {

    @objc
    public weak var conversationSettingsViewDelegate: ConversationSettingsViewDelegate?

    private(set) var threadViewModel: ThreadViewModel

    var thread: TSThread {
        threadViewModel.threadRecord
    }

    // Group model reflecting the last known group state.
    // This is updated as we change group membership, etc.
    var currentGroupModel: TSGroupModel? {
        guard let groupThread = thread as? TSGroupThread else {
            return nil
        }
        return groupThread.groupModel
    }

    var groupViewHelper: GroupViewHelper

    @objc
    public var showVerificationOnAppear = false

    var disappearingMessagesConfiguration: OWSDisappearingMessagesConfiguration
    var avatarView: UIImageView?

    // This is currently disabled behind a feature flag.
    private var colorPicker: ColorPicker?

    var isShowingAllGroupMembers = false
    var isShowingAllMutualGroups = false

    @objc
    public required init(threadViewModel: ThreadViewModel) {
        self.threadViewModel = threadViewModel
        groupViewHelper = GroupViewHelper(threadViewModel: threadViewModel)

        disappearingMessagesConfiguration = Self.databaseStorage.read { transaction in
            OWSDisappearingMessagesConfiguration.fetchOrBuildDefault(with: threadViewModel.threadRecord,
                                                                     transaction: transaction)
        }

        super.init()

        callService.addObserver(observer: self, syncStateImmediately: false)
        databaseStorage.appendUIDatabaseSnapshotDelegate(self)
        contactsViewHelper.addObserver(self)
        groupViewHelper.delegate = self
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(identityStateDidChange(notification:)),
                                               name: .identityStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(otherUsersProfileDidChange(notification:)),
                                               name: .otherUsersProfileDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(profileWhitelistDidChange(notification:)),
                                               name: .profileWhitelistDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateTableContents),
                                               name: UIContentSizeCategory.didChangeNotification,
                                               object: nil)
    }

    // MARK: - Accessors

    var canEditConversationAttributes: Bool {
        return groupViewHelper.canEditConversationAttributes
    }

    var canEditConversationMembership: Bool {
        return groupViewHelper.canEditConversationMembership
    }

    // Can local user edit group access.
    var canEditConversationAccess: Bool {
        return groupViewHelper.canEditConversationAccess
    }

    var isLocalUserFullMember: Bool {
        return groupViewHelper.isLocalUserFullMember
    }

    var isLocalUserFullOrInvitedMember: Bool {
        return groupViewHelper.isLocalUserFullOrInvitedMember
    }

    var isGroupThread: Bool {
        return thread.isGroupThread
    }

    // MARK: - View Lifecycle

    @objc
    public override func viewDidLoad() {
        super.viewDidLoad()

        defaultSeparatorInsetLeading = Self.cellHInnerMargin + 24 + OWSTableItem.iconSpacing

        if isGroupThread {
            updateNavigationBar()
        }

        // The header should "extend" offscreen so that we
        // don't see the root view's background color if we scroll down.
        let backgroundTopView = UIView()
        backgroundTopView.backgroundColor = tableBackgroundColor
        tableView.addSubview(backgroundTopView)
        backgroundTopView.autoPinEdge(.leading, to: .leading, of: view, withOffset: 0)
        backgroundTopView.autoPinEdge(.trailing, to: .trailing, of: view, withOffset: 0)
        let backgroundTopSize: CGFloat = 300
        backgroundTopView.autoSetDimension(.height, toSize: backgroundTopSize)
        backgroundTopView.autoPinEdge(.bottom, to: .top, of: tableView, withOffset: 0)

        if DebugFlags.shouldShowColorPicker {
            let colorPicker = ColorPicker(thread: self.thread)
            colorPicker.delegate = self
            self.colorPicker = colorPicker
        }

        observeNotifications()

        updateRecentAttachments()
        updateMutualGroupThreads()
        reloadThreadAndUpdateContent()

        updateNavigationBar()
    }

    func updateNavigationBar() {
        guard canEditConversationAttributes else {
            navigationItem.rightBarButtonItem = nil
            return
        }

        if isGroupThread || contactsManagerImpl.isSystemContactsAuthorized {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("CONVERSATION_SETTINGS_EDIT",
                                         comment: "Label for the 'edit' button in conversation settings view."),
                style: .plain,
                target: self,
                action: #selector(editButtonWasPressed))

        } else {
            navigationItem.rightBarButtonItem = nil
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if showVerificationOnAppear {
            showVerificationOnAppear = false
            if isGroupThread {
                showAllGroupMembers()
            } else {
                showVerificationView()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if let selectedPath = tableView.indexPathForSelectedRow {
            // HACK to unselect rows when swiping back
            // http://stackoverflow.com/questions/19379510/uitableviewcell-doesnt-get-deselected-when-swiping-back-quickly
            tableView.deselectRow(at: selectedPath, animated: animated)
        }

        updateTableContents()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in } completion: { _ in
            self.updateTableContents()
        }
    }

    // MARK: -

    private(set) var groupMemberStateMap = [SignalServiceAddress: OWSVerificationState]()
    private(set) var sortedGroupMembers = [SignalServiceAddress]()
    func updateGroupMembers(transaction: SDSAnyReadTransaction) {
        guard let groupModel = currentGroupModel, !groupModel.isPlaceholder, let localAddress = tsAccountManager.localAddress else {
            groupMemberStateMap = [:]
            sortedGroupMembers = []
            return
        }

        let groupMembership = groupModel.groupMembership
        let allMembers = groupMembership.fullMembers
        var allMembersSorted = [SignalServiceAddress]()
        var verificationStateMap = [SignalServiceAddress: OWSVerificationState]()

        for memberAddress in allMembers {
            verificationStateMap[memberAddress] = self.identityManager.verificationState(for: memberAddress,
                                                                                         transaction: transaction)
        }
        allMembersSorted = self.contactsManagerImpl.sortSignalServiceAddresses(Array(allMembers),
                                                                               transaction: transaction)

        var membersToRender = [SignalServiceAddress]()
        if groupMembership.isFullMember(localAddress) {
            // Make sure local user is first.
            membersToRender.insert(localAddress, at: 0)
        }
        // Admin users are second.
        let adminMembers = allMembersSorted.filter { $0 != localAddress && groupMembership.isFullMemberAndAdministrator($0) }
        membersToRender += adminMembers
        // Non-admin users are third.
        let nonAdminMembers = allMembersSorted.filter { $0 != localAddress && !groupMembership.isFullMemberAndAdministrator($0) }
        membersToRender += nonAdminMembers

        self.groupMemberStateMap = verificationStateMap
        self.sortedGroupMembers = membersToRender
    }

    func reloadThreadAndUpdateContent() {
        let didUpdate = self.databaseStorage.read { transaction -> Bool in
            guard let newThread = TSThread.anyFetch(uniqueId: self.thread.uniqueId,
                                                    transaction: transaction) else {
                return false
            }
            let newThreadViewModel = ThreadViewModel(thread: newThread,
                                                     forConversationList: false,
                                                     transaction: transaction)
            self.threadViewModel = newThreadViewModel
            self.groupViewHelper = GroupViewHelper(threadViewModel: newThreadViewModel)
            self.groupViewHelper.delegate = self

            self.updateGroupMembers(transaction: transaction)

            return true
        }

        if !didUpdate {
            owsFailDebug("Invalid thread.")
            navigationController?.popViewController(animated: true)
            return
        }

        updateTableContents()
    }

    var lastContentWidth: CGFloat?

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Reload the table content if this view's width changes.
        var hasContentWidthChanged = false
        if let lastContentWidth = lastContentWidth,
            lastContentWidth != view.width {
            hasContentWidthChanged = true
        }

        if hasContentWidthChanged {
            updateTableContents()
        }
    }

    // MARK: -

    func didSelectGroupMember(_ memberAddress: SignalServiceAddress) {
        guard memberAddress.isValid else {
            owsFailDebug("Invalid address.")
            return
        }
        let memberActionSheet = MemberActionSheet(address: memberAddress, groupViewHelper: groupViewHelper)
        memberActionSheet.present(fromViewController: self)
    }

    func showAddToSystemContactsActionSheet(contactThread: TSContactThread) {
        let actionSheet = ActionSheetController()
        let createNewTitle = NSLocalizedString("CONVERSATION_SETTINGS_NEW_CONTACT",
                                               comment: "Label for 'new contact' button in conversation settings view.")
        actionSheet.addAction(ActionSheetAction(title: createNewTitle,
                                                style: .default,
                                                handler: { [weak self] _ in
                                                    self?.presentContactViewController()
        }))

        let addToExistingTitle = NSLocalizedString("CONVERSATION_SETTINGS_ADD_TO_EXISTING_CONTACT",
                                                   comment: "Label for 'new contact' button in conversation settings view.")
        actionSheet.addAction(ActionSheetAction(title: addToExistingTitle,
                                                style: .default,
                                                handler: { [weak self] _ in
                                                    self?.presentAddToContactViewController(address:
                                                        contactThread.contactAddress)
        }))

        actionSheet.addAction(OWSActionSheets.cancelAction)

        self.presentActionSheet(actionSheet)
    }

    // MARK: -

    private var hasUnsavedChangesToDisappearingMessagesConfiguration: Bool {
        return databaseStorage.read { transaction in
            if let groupThread = self.thread as? TSGroupThread {
                guard let latestThread = TSGroupThread.fetch(groupId: groupThread.groupModel.groupId, transaction: transaction) else {
                    // Thread no longer exists.
                    return false
                }
                guard latestThread.isLocalUserMemberOfAnyKind else {
                    // Local user is no longer in group, e.g. perhaps they just blocked it.
                    return false
                }
            }
            return self.disappearingMessagesConfiguration.hasChanged(with: transaction)
        }
    }

    // MARK: - Actions

    func tappedAvatar() {
        guard avatarView != nil, !thread.isGroupThread || (thread as? TSGroupThread)?.groupModel.groupAvatarData != nil else {
            return // Not a valid avatar
        }

        presentAvatarViewController()
    }

    func showVerificationView() {
        guard let contactThread = thread as? TSContactThread else {
            owsFailDebug("Invalid thread.")
            return
        }
        let contactAddress = contactThread.contactAddress
        assert(contactAddress.isValid)
        FingerprintViewController.present(from: self, address: contactAddress)
    }

    func showWallpaperSettingsView() {
        let vc = WallpaperSettingsViewController(thread: thread)
        navigationController?.pushViewController(vc, animated: true)
    }

    func showSoundAndNotificationsSettingsView() {
        let vc = SoundAndNotificationsSettingsViewController(thread: thread)
        navigationController?.pushViewController(vc, animated: true)
    }

    func showPermissionsSettingsView() {
        let vc = GroupPermissionsSettingsViewController(threadViewModel: threadViewModel, delegate: self)
        presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
    }

    func showAllGroupMembers(revealingIndices: [IndexPath]? = nil) {
        isShowingAllGroupMembers = true
        updateForSeeAll(revealingIndices: revealingIndices)
    }

    func showAllMutualGroups(revealingIndices: [IndexPath]? = nil) {
        isShowingAllMutualGroups = true
        updateForSeeAll(revealingIndices: revealingIndices)
    }

    func updateForSeeAll(revealingIndices: [IndexPath]? = nil) {
        if let revealingIndices = revealingIndices, !revealingIndices.isEmpty, let firstIndex = revealingIndices.first {
            tableView.beginUpdates()

            // Delete the "See All" row.
            tableView.deleteRows(at: [IndexPath(row: firstIndex.row, section: firstIndex.section)], with: .top)

            // Insert the new rows.
            tableView.insertRows(at: revealingIndices, with: .top)

            updateTableContents(shouldReload: false)
            tableView.endUpdates()
        } else {
            updateTableContents()
        }
    }

    func showGroupAttributesView(editAction: GroupAttributesViewController.EditAction) {
         guard canEditConversationAttributes else {
             owsFailDebug("!canEditConversationAttributes")
             return
         }

         assert(conversationSettingsViewDelegate != nil)

         guard let groupThread = thread as? TSGroupThread else {
             owsFailDebug("Invalid thread.")
             return
         }
         let groupAttributesViewController = GroupAttributesViewController(groupThread: groupThread,
                                                                           editAction: editAction,
                                                                           delegate: self)
         navigationController?.pushViewController(groupAttributesViewController, animated: true)
     }

    func showAddMembersView() {
        guard canEditConversationMembership else {
            owsFailDebug("Can't edit membership.")
            return
        }
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return
        }
        let addGroupMembersViewController = AddGroupMembersViewController(groupThread: groupThread)
        addGroupMembersViewController.addGroupMembersViewControllerDelegate = self
        navigationController?.pushViewController(addGroupMembersViewController, animated: true)
    }

    func showAddToGroupView() {
        guard let thread = thread as? TSContactThread else {
            return owsFailDebug("Tried to present for unexpected thread")
        }
        let vc = AddToGroupViewController(address: thread.contactAddress)
        presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
    }

    func showMemberRequestsAndInvitesView() {
        guard let viewController = buildMemberRequestsAndInvitesView() else {
            owsFailDebug("Invalid thread.")
            return
        }
        navigationController?.pushViewController(viewController, animated: true)
    }

    @objc
    public func buildMemberRequestsAndInvitesView() -> UIViewController? {
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return nil
        }
        let groupMemberRequestsAndInvitesViewController = GroupMemberRequestsAndInvitesViewController(groupThread: groupThread,
                                                                                                      groupViewHelper: groupViewHelper)
        groupMemberRequestsAndInvitesViewController.groupMemberRequestsAndInvitesViewControllerDelegate = self
        return groupMemberRequestsAndInvitesViewController
    }

    func showGroupLinkView() {
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return
        }
        guard let groupModelV2 = groupThread.groupModel as? TSGroupModelV2 else {
            owsFailDebug("Invalid groupModel.")
            return
        }
        let groupLinkViewController = GroupLinkViewController(groupModelV2: groupModelV2)
        groupLinkViewController.groupLinkViewControllerDelegate = self
        navigationController?.pushViewController(groupLinkViewController, animated: true)
    }

    func presentContactViewController() {
        if !contactsManagerImpl.supportsContactEditing {
            owsFailDebug("Contact editing not supported")
            return
        }
        guard let contactThread = thread as? TSContactThread else {
            owsFailDebug("Invalid thread.")
            return
        }

        guard let contactViewController =
                contactsViewHelper.contactViewController(for: contactThread.contactAddress, editImmediately: true) else {
            owsFailDebug("Unexpectedly missing contact VC")
            return
        }

        contactViewController.delegate = self
        navigationController?.pushViewController(contactViewController, animated: true)
    }

    func presentAvatarViewController() {
        guard let avatarView = avatarView, avatarView.image != nil else { return }
        guard let vc = databaseStorage.read(block: { readTx in
            AvatarViewController(thread: self.thread, readTx: readTx)
        }) else {
            return
        }

        present(vc, animated: true)
    }

    private func presentAddToContactViewController(address: SignalServiceAddress) {

        if !contactsManagerImpl.supportsContactEditing {
            // Should not expose UI that lets the user get here.
            owsFailDebug("Contact editing not supported.")
            return
        }

        if !contactsManagerImpl.isSystemContactsAuthorized {
            contactsViewHelper.presentMissingContactAccessAlertController(from: self)
            return
        }

        let viewController = OWSAddToContactViewController(address: address)
        navigationController?.pushViewController(viewController, animated: true)
    }

    func didTapLeaveGroup() {
        guard canLocalUserLeaveGroupWithoutChoosingNewAdmin else {
            showReplaceAdminAlert()
            return
        }
        showLeaveGroupConfirmAlert()
    }

    func showLeaveGroupConfirmAlert(replacementAdminUuid: UUID? = nil) {
        let alert = ActionSheetController(title: NSLocalizedString("CONFIRM_LEAVE_GROUP_TITLE",
                                                                   comment: "Alert title"),
                                          message: NSLocalizedString("CONFIRM_LEAVE_GROUP_DESCRIPTION",
                                                                     comment: "Alert body"))

        let leaveAction = ActionSheetAction(title: NSLocalizedString("LEAVE_BUTTON_TITLE",
                                                                     comment: "Confirmation button within contextual alert"),
                                            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "leave_group_confirm"),
                                            style: .destructive) { _ in
                                                self.leaveGroup(replacementAdminUuid: replacementAdminUuid)
        }
        alert.addAction(leaveAction)
        alert.addAction(OWSActionSheets.cancelAction)

        presentActionSheet(alert)
    }

    func showReplaceAdminAlert() {
        let candidates = self.replacementAdminCandidates
        guard !candidates.isEmpty else {
            // TODO: We could offer a "delete group locally" option here.
            OWSActionSheets.showErrorAlert(message: NSLocalizedString("GROUPS_CANT_REPLACE_ADMIN_ALERT_MESSAGE",
                                                                      comment: "Message for the 'can't replace group admin' alert."))
            return
        }

        let alert = ActionSheetController(title: NSLocalizedString("GROUPS_REPLACE_ADMIN_ALERT_TITLE",
                                                                   comment: "Title for the 'replace group admin' alert."),
                                          message: NSLocalizedString("GROUPS_REPLACE_ADMIN_ALERT_MESSAGE",
                                                                     comment: "Message for the 'replace group admin' alert."))

        alert.addAction(ActionSheetAction(title: NSLocalizedString("GROUPS_REPLACE_ADMIN_BUTTON",
                                                                   comment: "Label for the 'replace group admin' button."),
                                          accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "replace_admin_alert"),
                                          style: .default) { _ in
                                            self.showReplaceAdminView(candidates: candidates)
        })
        alert.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(alert)
    }

    func showReplaceAdminView(candidates: Set<SignalServiceAddress>) {
        assert(!candidates.isEmpty)
        let replaceAdminViewController = ReplaceAdminViewController(candidates: candidates,
                                                                    replaceAdminViewControllerDelegate: self)
        navigationController?.pushViewController(replaceAdminViewController, animated: true)
    }

    private var canLocalUserLeaveGroupWithoutChoosingNewAdmin: Bool {
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return true
        }
        guard let groupModelV2 = groupThread.groupModel as? TSGroupModelV2 else {
            return true
        }
        guard let localAddress = tsAccountManager.localAddress else {
            owsFailDebug("missing local address")
            return true
        }
        return GroupManager.canLocalUserLeaveGroupWithoutChoosingNewAdmin(localAddress: localAddress,
                                                                          groupMembership: groupModelV2.groupMembership)
    }

    private var replacementAdminCandidates: Set<SignalServiceAddress> {
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return []
        }
        guard let groupModelV2 = groupThread.groupModel as? TSGroupModelV2 else {
            return []
        }
        guard let localAddress = tsAccountManager.localAddress else {
            owsFailDebug("missing local address")
            return []
        }
        var candidates = groupModelV2.groupMembership.fullMembers
        candidates.remove(localAddress)
        return candidates
    }

    private func leaveGroup(replacementAdminUuid: UUID? = nil) {
        guard let groupThread = thread as? TSGroupThread else {
            owsFailDebug("Invalid thread.")
            return
        }
        guard let navigationController = self.navigationController else {
            owsFailDebug("Invalid navigationController.")
            return
        }
        // On success, we want to pop back to the conversation view controller.
        let viewControllers = navigationController.viewControllers
        guard let index = viewControllers.firstIndex(of: self),
            index > 0 else {
                owsFailDebug("Invalid navigation stack.")
                return
        }
        let conversationViewController = viewControllers[index - 1]
        GroupManager.leaveGroupOrDeclineInviteAsyncWithUI(groupThread: groupThread,
                                                          fromViewController: self,
                                                          replacementAdminUuid: replacementAdminUuid) {
                                                            self.navigationController?.popToViewController(conversationViewController,
                                                                                                           animated: true)
        }
    }

    func didTapUnblockThread(completion: @escaping () -> Void = {}) {
        let isCurrentlyBlocked = blockingManager.isThreadBlocked(thread)
        if !isCurrentlyBlocked {
            owsFailDebug("Not blocked.")
            return
        }
        BlockListUIUtils.showUnblockThreadActionSheet(thread, from: self) { [weak self] _ in
            self?.updateTableContents()
            completion()
        }
    }

    func didTapBlockThread() {
        let isCurrentlyBlocked = blockingManager.isThreadBlocked(thread)
        if isCurrentlyBlocked {
            owsFailDebug("Already blocked.")
            return
        }
        BlockListUIUtils.showBlockThreadActionSheet(thread, from: self) { [weak self] _ in
            self?.updateTableContents()
        }
    }

    class func showMuteUnmuteActionSheet(for thread: TSThread, from fromVC: UIViewController, actionExecuted: @escaping () -> Void) {
        var unmuteTitle: String?
        if thread.isMuted {
            let now = Date()

            if thread.mutedUntilTimestamp == TSThread.alwaysMutedTimestamp {
                unmuteTitle = NSLocalizedString(
                    "CONVERSATION_SETTINGS_MUTED_ALWAYS_UNMUTE",
                    comment: "Indicates that this thread is muted forever."
                )
            } else if let mutedUntilDate = thread.mutedUntilDate, mutedUntilDate > now {
                let calendar = Calendar.current
                let muteUntilComponents = calendar.dateComponents([.year, .month, .day], from: mutedUntilDate)
                let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)
                let dateFormatter = DateFormatter()
                if nowComponents.year != muteUntilComponents.year
                    || nowComponents.month != muteUntilComponents.month
                    || nowComponents.day != muteUntilComponents.day {

                    dateFormatter.dateStyle = .short
                    dateFormatter.timeStyle = .short
                } else {
                    dateFormatter.dateStyle = .none
                    dateFormatter.timeStyle = .short
                }

                let formatString = NSLocalizedString(
                    "CONVERSATION_SETTINGS_MUTED_UNTIL_UNMUTE_FORMAT",
                    comment: "Indicates that this thread is muted until a given date or time. Embeds {{The date or time which the thread is muted until}}."
                )
                unmuteTitle = String(
                    format: formatString,
                    dateFormatter.string(from: mutedUntilDate)
                )
            }
        }

        let actionSheet = ActionSheetController(
            title: thread.isMuted ? unmuteTitle : NSLocalizedString(
                "CONVERSATION_SETTINGS_MUTE_ACTION_SHEET_TITLE",
                comment: "Title for the mute action sheet"
            )
        )

        if thread.isMuted {
            let action =
                ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_UNMUTE_ACTION",
                                                           comment: "Label for button to unmute a thread."),
                                  accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "unmute")) { _ in
                    setThreadMutedUntilTimestamp(0, thread: thread)
                    actionExecuted()
                }
            actionSheet.addAction(action)
        } else {
            #if DEBUG
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ONE_MINUTE_ACTION",
                                                                             comment: "Label for button to mute a thread for a minute."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_1_minute")) { _ in
                setThreadMuted(thread: thread) {
                    var dateComponents = DateComponents()
                    dateComponents.minute = 1
                    return dateComponents
                }
                actionExecuted()
            })
            #endif
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ONE_HOUR_ACTION",
                                                                             comment: "Label for button to mute a thread for a hour."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_1_hour")) { _ in
                setThreadMuted(thread: thread) {
                    var dateComponents = DateComponents()
                    dateComponents.hour = 1
                    return dateComponents
                }
                actionExecuted()
            })
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_EIGHT_HOUR_ACTION",
                                                                             comment: "Label for button to mute a thread for eight hours."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_8_hour")) { _ in
                setThreadMuted(thread: thread) {
                    var dateComponents = DateComponents()
                    dateComponents.hour = 8
                    return dateComponents
                }
                actionExecuted()
            })
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ONE_DAY_ACTION",
                                                                             comment: "Label for button to mute a thread for a day."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_1_day")) { _ in
                setThreadMuted(thread: thread) {
                    var dateComponents = DateComponents()
                    dateComponents.day = 1
                    return dateComponents
                }
                actionExecuted()
            })
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ONE_WEEK_ACTION",
                                                                             comment: "Label for button to mute a thread for a week."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_1_week")) { _ in
                setThreadMuted(thread: thread) {
                    var dateComponents = DateComponents()
                    dateComponents.day = 7
                    return dateComponents
                }
                actionExecuted()
            })
            actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("CONVERSATION_SETTINGS_MUTE_ALWAYS_ACTION",
                                                                             comment: "Label for button to mute a thread forever."),
                                                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromVC, name: "mute_always")) { _ in
                setThreadMutedUntilTimestamp(TSThread.alwaysMutedTimestamp, thread: thread)
                actionExecuted()
            })
        }

        actionSheet.addAction(OWSActionSheets.cancelAction)
        fromVC.presentActionSheet(actionSheet)
    }

    private class func setThreadMuted(thread: TSThread, dateBlock: () -> DateComponents) {
        guard let timeZone = TimeZone(identifier: "UTC") else {
            owsFailDebug("Invalid timezone.")
            return
        }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let dateComponents = dateBlock()
        guard let mutedUntilDate = calendar.date(byAdding: dateComponents, to: Date()) else {
            owsFailDebug("Couldn't modify date.")
            return
        }
        self.setThreadMutedUntilTimestamp(mutedUntilDate.ows_millisecondsSince1970, thread: thread)
    }

    private class func setThreadMutedUntilTimestamp(_ value: UInt64, thread: TSThread) {
        databaseStorage.write { transaction in
            thread.updateWithMuted(untilTimestamp: value, updateStorageService: true, transaction: transaction)
        }
    }

    func showMediaGallery() {
        Logger.debug("")

        let tileVC = MediaTileViewController(thread: thread)
        navigationController?.pushViewController(tileVC, animated: true)
    }

    func showMediaPageView(for attachmentStream: TSAttachmentStream) {
        let vc = MediaPageViewController(initialMediaAttachment: attachmentStream, thread: thread)
        present(vc, animated: true)
    }

    let maximumRecentMedia = 4
    private(set) var recentMedia = OrderedDictionary<String, (attachment: TSAttachmentStream, imageView: UIImageView)>() {
        didSet { AssertIsOnMainThread() }
    }
    private lazy var mediaGalleryFinder = MediaGalleryFinder(thread: thread)
    func updateRecentAttachments() {
        let recentAttachments = databaseStorage.uiRead { transaction in
            mediaGalleryFinder.recentMediaAttachments(limit: maximumRecentMedia, transaction: transaction.unwrapGrdbRead)
        }
        recentMedia = recentAttachments.reduce(into: OrderedDictionary(), { result, attachment in
            guard let attachmentStream = attachment as? TSAttachmentStream else {
                return owsFailDebug("Unexpected type of attachment")
            }

            let imageView = UIImageView()
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 4
            imageView.contentMode = .scaleAspectFill

            imageView.image = attachmentStream.thumbnailImageSmall { imageView.image = $0 } failure: {}

            result.append(key: attachmentStream.uniqueId, value: (attachmentStream, imageView))
        })
    }

    private(set) var mutualGroupThreads = [TSGroupThread]() {
        didSet { AssertIsOnMainThread() }
    }
    private(set) var hasGroupThreads = false {
        didSet { AssertIsOnMainThread() }
    }
    func updateMutualGroupThreads() {
        guard let contactThread = thread as? TSContactThread else { return }
        databaseStorage.uiRead { transaction in
            self.hasGroupThreads = GRDBThreadFinder.existsGroupThread(transaction: transaction.unwrapGrdbRead)
            self.mutualGroupThreads = TSGroupThread.groupThreads(
                with: contactThread.contactAddress,
                transaction: transaction
            ).filter { $0.isLocalUserFullMember && $0.shouldThreadBeVisible }
        }
    }

    func tappedConversationSearch() {
        conversationSettingsViewDelegate?.conversationSettingsDidRequestConversationSearch()
    }

    @objc
    func editButtonWasPressed(_ sender: Any) {
        owsAssertDebug(canEditConversationAttributes)

        if isGroupThread {
            showGroupAttributesView(editAction: .none)
        } else {
            presentContactViewController()
        }
    }

    // MARK: - Notifications

    @objc
    private func identityStateDidChange(notification: Notification) {
        AssertIsOnMainThread()

        updateTableContents()
    }

    @objc
    private func otherUsersProfileDidChange(notification: Notification) {
        AssertIsOnMainThread()

        guard let address = notification.userInfo?[kNSNotificationKey_ProfileAddress] as? SignalServiceAddress,
            address.isValid else {
                owsFailDebug("Missing or invalid address.")
                return
        }
        guard let contactThread = thread as? TSContactThread else {
            return
        }

        if contactThread.contactAddress == address {
            updateTableContents()
        }
    }

    @objc
    private func profileWhitelistDidChange(notification: Notification) {
        AssertIsOnMainThread()

        // If profile whitelist just changed, we may need to refresh the view.
        if let address = notification.userInfo?[kNSNotificationKey_ProfileAddress] as? SignalServiceAddress,
            let contactThread = thread as? TSContactThread,
            contactThread.contactAddress == address {
            updateTableContents()
        }

        if let groupId = notification.userInfo?[kNSNotificationKey_ProfileGroupId] as? Data,
            let groupThread = thread as? TSGroupThread,
            groupThread.groupModel.groupId == groupId {
            updateTableContents()
        }
    }
}

// MARK: -

extension ConversationSettingsViewController: ContactsViewHelperObserver {

    func contactsViewHelperDidUpdateContacts() {
        updateTableContents()
    }
}

// MARK: -

extension ConversationSettingsViewController: CNContactViewControllerDelegate {

    public func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        updateTableContents()
        navigationController?.popToViewController(self, animated: true)
    }
}

// MARK: -

extension ConversationSettingsViewController: ColorPickerDelegate {

    func showColorPicker() {
        guard let colorPicker = colorPicker else {
            owsFailDebug("Missing colorPicker.")
            return
        }
        let sheetViewController = colorPicker.sheetViewController
        sheetViewController.delegate = self
        self.present(sheetViewController, animated: true) {
            Logger.info("presented sheet view")
        }
    }

    public func colorPicker(_ colorPicker: ColorPicker, didPickConversationColor conversationColor: OWSConversationColor) {
        Logger.debug("picked color: \(conversationColor.name)")
        databaseStorage.write { transaction in
            self.thread.updateConversationColorName(conversationColor.name, transaction: transaction)
        }

        contactsManagerImpl.removeAllFromAvatarCache()
        contactsManagerImpl.clearColorNameCache()
        updateTableContents()
        conversationSettingsViewDelegate?.conversationColorWasUpdated()

        DispatchQueue.global().async {
            let operation = ConversationConfigurationSyncOperation(thread: self.thread)
            assert(operation.isReady)
            operation.start()
        }
    }
}

// MARK: -

extension ConversationSettingsViewController: GroupAttributesViewControllerDelegate {
    func groupAttributesDidUpdate() {
        reloadThreadAndUpdateContent()
    }
}

// MARK: -

extension ConversationSettingsViewController: AddGroupMembersViewControllerDelegate {
    func addGroupMembersViewDidUpdate() {
        reloadThreadAndUpdateContent()
    }
}

// MARK: -

extension ConversationSettingsViewController: GroupMemberRequestsAndInvitesViewControllerDelegate {
    func requestsAndInvitesViewDidUpdate() {
        reloadThreadAndUpdateContent()
    }
}

// MARK: -

extension ConversationSettingsViewController: GroupLinkViewControllerDelegate {
    func groupLinkViewViewDidUpdate() {
        reloadThreadAndUpdateContent()
    }
}

// MARK: -

extension ConversationSettingsViewController: SheetViewControllerDelegate {
    public func sheetViewControllerRequestedDismiss(_ sheetViewController: SheetViewController) {
        dismiss(animated: true)
    }
}

// MARK: -

extension ConversationSettingsViewController: OWSNavigationView {

    public func shouldCancelNavigationBack() -> Bool {
        let result = hasUnsavedChangesToDisappearingMessagesConfiguration
        if result {
            self.updateDisappearingMessagesConfigurationAndDismiss()
        }
        return result
    }

    @objc
    public static func showUnsavedChangesActionSheet(from fromViewController: UIViewController,
                                                     saveBlock: @escaping () -> Void,
                                                     discardBlock: @escaping () -> Void) {
        let actionSheet = ActionSheetController(title: NSLocalizedString("CONVERSATION_SETTINGS_UNSAVED_CHANGES_TITLE",
                                                                         comment: "The alert title if user tries to exit conversation settings view without saving changes."),
                                                message: NSLocalizedString("CONVERSATION_SETTINGS_UNSAVED_CHANGES_MESSAGE",
                                                                           comment: "The alert message if user tries to exit conversation settings view without saving changes."))
        actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("ALERT_SAVE",
                                                                         comment: "The label for the 'save' button in action sheets."),
                                                accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromViewController, name: "save"),
                                                style: .default) { _ in
                                                    saveBlock()
        })
        actionSheet.addAction(ActionSheetAction(title: NSLocalizedString("ALERT_DONT_SAVE",
                                                                         comment: "The label for the 'don't save' button in action sheets."),
                                                accessibilityIdentifier: UIView.accessibilityIdentifier(in: fromViewController, name: "dont_save"),
                                                style: .destructive) { _ in
                                                    discardBlock()
        })
        fromViewController.presentActionSheet(actionSheet)
    }

    private func updateDisappearingMessagesConfigurationAndDismiss() {
        let dmConfiguration: OWSDisappearingMessagesConfiguration = disappearingMessagesConfiguration
        let thread = self.thread
        GroupViewUtils.updateGroupWithActivityIndicator(fromViewController: self,
                                                        updatePromiseBlock: {
                                                            self.updateDisappearingMessagesConfigurationPromise(dmConfiguration,
                                                                                                                thread: thread)
        },
                                                        completion: { [weak self] _ in
                                                            self?.navigationController?.popViewController(animated: true)
        })
    }

    private func updateDisappearingMessagesConfigurationPromise(_ dmConfiguration: OWSDisappearingMessagesConfiguration,
                                                                thread: TSThread) -> Promise<Void> {

        return firstly { () -> Promise<Void> in
            return GroupManager.messageProcessingPromise(for: thread,
                                                         description: "Update disappearing messages configuration")
        }.map(on: .global()) {
            // We're sending a message, so we're accepting any pending message request.
            ThreadUtil.addToProfileWhitelistIfEmptyOrPendingRequestWithSneakyTransaction(thread: thread)
        }.then(on: .global()) {
            GroupManager.localUpdateDisappearingMessages(thread: thread,
                                                         disappearingMessageToken: dmConfiguration.asToken)
        }
    }
}

// MARK: -

extension ConversationSettingsViewController: GroupViewHelperDelegate {
    func groupViewHelperDidUpdateGroup() {
        reloadThreadAndUpdateContent()
    }

    var fromViewController: UIViewController? {
        return self
    }
}

// MARK: -

extension ConversationSettingsViewController: ReplaceAdminViewControllerDelegate {
    func replaceAdmin(uuid: UUID) {
        showLeaveGroupConfirmAlert(replacementAdminUuid: uuid)
    }
}

extension ConversationSettingsViewController: MediaPresentationContextProvider {
    func mediaPresentationContext(item: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        let mediaView: UIView
        switch item {
        case .gallery(let galleryItem):
            guard let imageView = recentMedia[galleryItem.attachmentStream.uniqueId]?.imageView else { return nil }
            mediaView = imageView
        case .image:
            guard let avatarView = self.avatarView else { return nil }
            mediaView = avatarView
        }

        guard let mediaSuperview = mediaView.superview else {
            owsFailDebug("mediaSuperview was unexpectedly nil")
            return nil
        }

        let presentationFrame = coordinateSpace.convert(mediaView.frame, from: mediaSuperview)

        return MediaPresentationContext(mediaView: mediaView, presentationFrame: presentationFrame, cornerRadius: 0)
    }

    func snapshotOverlayView(in coordinateSpace: UICoordinateSpace) -> (UIView, CGRect)? {
        return nil
    }
}

extension ConversationSettingsViewController: GroupPermissionsSettingsDelegate {
    func groupPermissionSettingsDidUpdate() {
        reloadThreadAndUpdateContent()
    }
}

extension ConversationSettingsViewController: UIDatabaseSnapshotDelegate {
    public func uiDatabaseSnapshotWillUpdate() {}

    public func uiDatabaseSnapshotDidUpdate(databaseChanges: UIDatabaseChanges) {
        AssertIsOnMainThread()

        var didUpdate = false

        if databaseChanges.didUpdateModel(collection: TSAttachment.collection()) {
            updateRecentAttachments()
            didUpdate = true
        }

        if databaseChanges.didUpdateModel(collection: TSGroupMember.collection()) {
            updateMutualGroupThreads()
            didUpdate = true
        }

        if didUpdate {
            updateTableContents()
        }
    }

    public func uiDatabaseSnapshotDidUpdateExternally() {
        AssertIsOnMainThread()

        updateRecentAttachments()
        updateMutualGroupThreads()
        updateTableContents()
    }

    public func uiDatabaseSnapshotDidReset() {
        AssertIsOnMainThread()

        updateRecentAttachments()
        updateMutualGroupThreads()
        updateTableContents()
    }
}

extension ConversationSettingsViewController: CallServiceObserver {
    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        updateTableContents()
    }
}
