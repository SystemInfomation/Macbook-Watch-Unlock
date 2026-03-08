import Cocoa
import Quartz
import ServiceManagement

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    let prefs = UserDefaults.standard
    var systemSleep = false
    var connected = false
    var userNotification: NSUserNotification?
    var aboutBox: AboutBox? = nil
    var manualLock = false
    var unlockedAt = 0.0
    var lastRSSI: Int? = nil
    let unlockGracePeriod = 15.0

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        var desc : String!
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
        } else {
            desc = device.description
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
    }
    
    func newDevice(device: Device) {
        let menuItem = deviceMenu.addItem(withTitle: menuItemTitle(device: device), action:#selector(selectDevice), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        if (device.uuid == ble.monitoredUUID) {
            menuItem.state = .on
        }
    }
    
    func updateDevice(device: Device) {
        if let menu = deviceDict[device.uuid] {
            menu.title = menuItemTitle(device: device)
        }
    }
    
    func removeDevice(device: Device) {
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        if let r = rssi {
            lastRSSI = r
            monitorMenuItem?.title = String(format:"%ddBm", r) + (active ? " (Active)" : "")
            if (!connected) {
                connected = true
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("not_detected")
            if (connected) {
                connected = false
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String) {
        let un = NSUserNotification()
        un.title = "BLEUnlock"
        if reason == "lost" {
            un.subtitle = t("notification_lost_signal")
        } else if reason == "away" {
            un.subtitle = t("notification_device_away")
        }
        un.informativeText = t("notification_locked")
        un.deliveryDate = Date().addingTimeInterval(1)
        NSUserNotificationCenter.default.scheduleNotification(un)
        userNotification = un
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if notification != userNotification {
            NSWorkspace.shared.open(URL(string: "https://github.com/ts1/BLEUnlock/releases")!)
            NSUserNotificationCenter.default.removeDeliveredNotification(notification)
        }
    }

    func lockOrSaveScreen() {
        if SACLockScreenImmediate() != 0 {
            print("Failed to lock screen")
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            // Device is back - just clear notifications, but don't unlock
            if let un = userNotification {
                NSUserNotificationCenter.default.removeDeliveredNotification(un)
                userNotification = nil
            }
        } else {
            let now = Date().timeIntervalSince1970
            if now < unlockedAt + unlockGracePeriod {
                // Avoid re-locking right after manual unlock while BLE reconnects.
                manualLock = false
                return
            }
            // Device is away - lock the screen
            if (!isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED) {
                lockOrSaveScreen()
                notifyUser(reason)
            }
            manualLock = false
        }
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }
    
    @objc func onDisplayWake() {
        print("display wake")
    }

    @objc func onDisplaySleep() {
        print("display sleep")
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            print("delayed system wake job")
            NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
            self.systemSleep = false
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
    }

    @objc func onUnlock() {
        unlockedAt = Date().timeIntervalSince1970
        if let un = userNotification {
            NSUserNotificationCenter.default.removeDeliveredNotification(un)
            userNotification = nil
        }
        if let uuid = ble.monitoredUUID {
            monitorDevice(uuid: uuid)
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            print("onUnlock")
        })
        manualLock = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            checkUpdate()
        })
    }

    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                monitorDevice(uuid: uuid)
                prefs.set(uuid.uuidString, forKey: "device")
                menuItem.state = .on
            } else {
                menuItem.state = .off
            }
        }
    }

    func monitorDevice(uuid: UUID) {
        connected = false
        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
        monitorMenuItem?.title = t("not_detected")
        ble.startMonitor(uuid: uuid)
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, launchAtLogin)
    }

    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        manualLock = true
        lockOrSaveScreen()
    }
    
    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "1 " + t("second"), action: #selector(setLockDelay), keyEquivalent: "").tag = 1
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if (!AXIsProcessTrustedWithOptions([key: true] as CFDictionary)) {
            // Sometimes Prompt option above doesn't work.
            // Actually trying to send key may open that dialog.
            let src = CGEventSource(stateID: .hidSystemState)
            // "Fn" key down and up
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        ble.delegate = self
        if let str = prefs.string(forKey: "device") {
            if let uuid = UUID(uuidString: str) {
                monitorDevice(uuid: uuid)
            }
        }
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        let timeout = prefs.integer(forKey: "timeout")
        if timeout != 0 {
            ble.signalTimeout = Double(timeout)
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }
        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        } else {
            // Default lock delay to 1 second if not set
            ble.proximityTimeout = 1.0
            prefs.set(1, forKey: "lockDelay")
        }

        NSUserNotificationCenter.default.delegate = self

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)

        checkUpdate()

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
    }
}
