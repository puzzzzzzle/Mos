//
//  PreferencesViewController.swift
//  Mos
//  基础选项界面
//  Created by Caldis on 2017/1/15.
//  Copyright © 2017年 Caldis. All rights reserved.
//

import Cocoa

class PreferencesGeneralViewController: NSViewController {
    
    // UI Elements
    @IBOutlet weak var launchOnLoginCheckBox: NSButton!
    @IBOutlet weak var hideStatusBarIconCheckBox: NSButton!
    @IBOutlet weak var hideStatusBarIconDescription: NSTextField!

    private let trackpadTapCheckBox = NSButton()
    private var trackpadTapObserver: NSObjectProtocol?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configureTrackpadTapControls()
        trackpadTapObserver = NotificationCenter.default.addObserver(
            forName: TrackpadTapManager.enabledDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncViewWithOptions()
        }
        // 读取设置
        syncViewWithOptions()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncViewWithOptions()
    }

    deinit {
        if let observer = trackpadTapObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func configureTrackpadTapControls() {
        let separator = NSBox()
        separator.boxType = .separator

        trackpadTapCheckBox.setButtonType(.switch)
        trackpadTapCheckBox.title = NSLocalizedString("trackpadTapCopyPaste", comment: "Trackpad tap copy and paste preference")
        trackpadTapCheckBox.target = self
        trackpadTapCheckBox.action = #selector(trackpadTapClick(_:))

        let description = NSTextField(wrappingLabelWithString:
            NSLocalizedString("trackpadTapCopyPasteHelp", comment: "Trackpad tap mapping and session lifetime"))
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        description.setContentCompressionResistancePriority(.required, for: .vertical)
        trackpadTapCheckBox.toolTip = description.stringValue

        for control in [separator, trackpadTapCheckBox, description] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: hideStatusBarIconDescription.bottomAnchor, constant: 20),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            trackpadTapCheckBox.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            trackpadTapCheckBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            trackpadTapCheckBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            description.topAnchor.constraint(equalTo: trackpadTapCheckBox.bottomAnchor, constant: 6),
            description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 38),
            description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(equalTo: description.bottomAnchor, constant: 20)
        ])
    }

    @objc private func trackpadTapClick(_ sender: NSButton) {
        if !TrackpadTapManager.shared.setEnabled(sender.state == .on) {
            Toast.show(NSLocalizedString("trackpadTapUnavailable", comment: "Trackpad tap listener unavailable"), style: .warning)
        }
        syncViewWithOptions()
    }
    
    // 自启
    @IBAction func launchOnLoginClick(_ sender: NSButton) {
        Options.shared.general.autoLaunch = sender.state.rawValue==0 ? false : true
        syncViewWithOptions()
    }
    
    // 隐藏
    @IBAction func hideStatusBarIconClick(_ sender: NSButton) {
        Options.shared.general.hideStatusItem = sender.state.rawValue==0 ? false : true
        syncViewWithOptions()
    }
}

/**
 * 设置同步
 **/
extension PreferencesGeneralViewController {
    // 同步界面与设置
    func syncViewWithOptions() {
        // 自启
        launchOnLoginCheckBox.state = NSControl.StateValue(rawValue: Options.shared.general.autoLaunch ? 1 : 0)
        // 隐藏
        hideStatusBarIconCheckBox.state = NSControl.StateValue(rawValue: Options.shared.general.hideStatusItem ? 1 : 0)
        trackpadTapCheckBox.state = TrackpadTapManager.shared.isEnabled ? .on : .off
    }
}
