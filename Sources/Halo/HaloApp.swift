// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Yordi de Kleijn

import SwiftUI

@main
struct HaloApp: App {
    @StateObject private var monitor = Monitor()
    @State private var open = false

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
                .onAppear { monitor.popoverDidChange(open: true) }
                .onDisappear { monitor.popoverDidChange(open: false) }
        } label: {
            // The icon is the product: it answers "is it working, how far" without a click.
            HStack(spacing: 4) {
                Image(systemName: monitor.phase.symbol)
                if let label = monitor.menuBarLabel {
                    Text(label).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}