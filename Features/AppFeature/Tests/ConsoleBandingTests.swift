import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The console's switch strip is **pure icon** — the fill is the whole message —
/// so the mapping from state to fill is the only thing standing between the human
/// and a lie. These pin the three readings that are not "on = true".
@Suite struct SwitchTileModeTests {
    // MARK: System Proxy

    @Test func systemProxyHeldByAnotherApp_isAWarning_notOff() {
        // The bug this prevents: rendering `.other` as off. The machine's traffic
        // IS being routed — through Charles — and Loom's control shows the same
        // fill as "nothing is configured", so the reader presses it, takes the
        // setting, and Loom will not hand it back (AGENTS.md § system proxy).
        #expect(PanelTile.Mode.systemProxy(.other(host: "127.0.0.1", port: 8888)) == .warning)
        #expect(PanelTile.Mode.systemProxy(.off) == .off)
        #expect(PanelTile.Mode.systemProxy(.loom) == .on)
    }

    // MARK: HTTPS

    @Test func httpsWithUntrustedCA_isAWarning_notOn() {
        // Interception on with an untrusted root CA decrypts nothing, so `.on`
        // would be a lie the whole capture rests on.
        #expect(PanelTile.Mode.https(sslEnabled: true, trust: .notTrusted) == .warning)
        #expect(PanelTile.Mode.https(sslEnabled: true, trust: .notGenerated) == .warning)
        #expect(PanelTile.Mode.https(sslEnabled: true, trust: .trusted) == .on)
    }

    @Test func httpsOff_isOff_regardlessOfTrust() {
        // A trusted CA with interception off is still off — the CA is not the
        // switch, and showing it as on would explain nothing about an empty
        // capture.
        #expect(PanelTile.Mode.https(sslEnabled: false, trust: .trusted) == .off)
        #expect(PanelTile.Mode.https(sslEnabled: false, trust: .notTrusted) == .off)
    }

    @Test func httpsWarningPredicateMatchesTheTrustCardGate() {
        // The tile and `CertificateTrustCard`'s visibility must agree: a warning
        // tile whose repair card is not showing is a dead end, because the tile's
        // own tap turns interception off — the opposite of the fix.
        for trust in [CertificateTrustState.notGenerated, .notTrusted, .trusted] {
            let cardShows = !trust.isReady
            let tileWarns = PanelTile.Mode.https(sslEnabled: true, trust: trust) == .warning
            #expect(cardShows == tileWarns)
        }
    }

    // MARK: Rules

    @Test func rulesOnWithNoRules_staysOn_neverWarning() {
        // Deliberately not a fault: that is a fresh install. Orange here would
        // teach the reader to ignore orange, which is the signal the SSL Scope
        // row and the breakpoint row depend on.
        #expect(PanelTile.Mode.rules(enabled: true) == .on)
        #expect(PanelTile.Mode.rules(enabled: false) == .off)
    }
}

/// The Connect Device control is on both surfaces, so its three states are one
/// definition. It used to be *hidden* in the main window while the proxy was
/// stopped — removing the control at exactly the moment someone is hunting for
/// why their phone can't reach Loom.
@Suite struct DeviceReadinessTests {
    @Test func proxyStoppedOutranksLANSetting() {
        // With nothing listening there is no address to point a phone at, so the
        // LAN setting is not the answer either way.
        #expect(DeviceReadiness(isRunning: false, lanEnabled: true) == .proxyStopped)
        #expect(DeviceReadiness(isRunning: false, lanEnabled: false) == .proxyStopped)
    }

    @Test func readyOnlyWhenBothHold() {
        #expect(DeviceReadiness(isRunning: true, lanEnabled: true) == .ready)
        #expect(DeviceReadiness(isRunning: true, lanEnabled: false) == .lanDisabled)
        #expect(DeviceReadiness(isRunning: true, lanEnabled: true).isReady)
        // On and not working is its own state, not a tint on `.ready`: the proxy is
        // up and this Mac captures normally, so only a phone can tell that anything
        // is wrong — which is why the glyph has to say it.
        #expect(
            DeviceReadiness(isRunning: true, lanEnabled: true, lanFailure: "port taken") == .lanUnreachable
        )
        #expect(DeviceReadiness(isRunning: true, lanEnabled: true, lanFailure: "port taken").isFailing)
        #expect(!DeviceReadiness(isRunning: true, lanEnabled: true, lanFailure: "port taken").isReady)
        // A failure recorded while LAN is off does not resurrect the state: the
        // switch is the more recent decision.
        #expect(
            DeviceReadiness(isRunning: true, lanEnabled: false, lanFailure: "port taken") == .lanDisabled
        )
        // Nor does it outrank a stopped proxy, which is the thing to fix first.
        #expect(
            DeviceReadiness(isRunning: false, lanEnabled: true, lanFailure: "port taken") == .proxyStopped
        )
        #expect(!DeviceReadiness(isRunning: true, lanEnabled: false).isReady)
    }

    @Test func theSlashMeansCannot_neverMeansTurnedOff() {
        // A slash is the word "unavailable". Using it for a setting the reader
        // switched off themselves would send them hunting a fault they caused on
        // purpose — so only the proxy-stopped state gets it.
        #expect(DeviceReadiness.proxyStopped.symbol == "iphone.slash")
        #expect(DeviceReadiness.lanDisabled.symbol == "iphone")
        #expect(DeviceReadiness.ready.symbol == "iphone.radiowaves.left.and.right")
    }

    @Test func eachStateSaysWhereTheFixIs() {
        // The control cannot start the proxy, so its help must point away from
        // itself rather than leave the reader clicking a dead end.
        #expect(DeviceReadiness.proxyStopped.help.contains("start it"))
        #expect(DeviceReadiness.lanDisabled.help != DeviceReadiness.ready.help)
    }
}
