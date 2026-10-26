import Foundation
import IOKit.ps

/// Battery level / power source / macOS Low Power Mode, with change callbacks.
final class PowerMonitor {
    struct State: Equatable {
        var onBattery = false
        var percent = 100
        var lowPowerMode = false
    }

    private(set) var state = State()
    var onChange: ((State) -> Void)?
    private var source: CFRunLoopSource?
    private var timer: Timer?

    init() {
        refresh()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        var s = State()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            s.onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
            if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for ps in list {
                    guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                          let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                    s.percent = cur * 100 / max
                }
            }
        }
        if s != state {
            state = s
            DispatchQueue.main.async { self.onChange?(s) }
        }
    }
}
