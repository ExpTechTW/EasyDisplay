import CoreGraphics
import Observation

/// An external monitor, dimmed through DisplayServices when macOS supports it (Apple
/// displays), otherwise through DDC/CI.
@MainActor
@Observable
final class ExternalDisplay: Identifiable {
    enum Control {
        case unknown
        case displayServices
        case ddc(DDCChannel, maximum: Int)
        case unsupported

        var label: String {
            switch self {
            case .unknown: L("control.detecting")
            case .displayServices: L("control.system")
            case .ddc: L("control.ddc")
            case .unsupported: L("control.unsupported")
            }
        }
    }

    let id: CGDirectDisplayID
    let name: String
    private(set) var control = Control.unknown
    /// 0…1, nil until read.
    private(set) var brightness: Double?

    @ObservationIgnored private var writer: LatestValueWriter<Double>?

    init(id: CGDirectDisplayID, name: String) {
        self.id = id
        self.name = name
    }

    var isControllable: Bool {
        switch control {
        case .displayServices, .ddc: true
        case .unknown, .unsupported: false
        }
    }

    func refresh() async {
        if case .unknown = control { await detectControl() }
        switch control {
        case .displayServices:
            brightness = await withTimeout { [id] in DisplayServices.brightness(id) } ?? nil
        case let .ddc(channel, _):
            guard let value = await channel.read(DDCChannel.brightnessVCP), value.maximum > 0 else { return }
            control = .ddc(channel, maximum: value.maximum)
            brightness = Double(value.current) / Double(value.maximum)
        case .unknown, .unsupported:
            break
        }
    }

    func setBrightness(_ value: Double) {
        brightness = value
        writer?.submit(value)
    }

    /// A brightness key: `step` is a fraction of the range, negative to dim.
    func brightnessKey(step: Double) {
        guard isControllable, let brightness else { return }
        setBrightness(min(1, max(0, brightness + step)))
    }

    private func detectControl() async {
        if (await withTimeout { [id] in DisplayServices.canChangeBrightness(id) }) == true {
            control = .displayServices
            writer = LatestValueWriter { [id] value in
                _ = await withTimeout { DisplayServices.setBrightness(id, value) }
            }
            return
        }
        guard let channel = DDCChannel.channel(for: id),
              let value = await channel.read(DDCChannel.brightnessVCP), value.maximum > 0
        else {
            control = .unsupported
            return
        }
        let maximum = value.maximum
        control = .ddc(channel, maximum: maximum)
        writer = LatestValueWriter { value in
            _ = await channel.write(DDCChannel.brightnessVCP, Int((value * Double(maximum)).rounded()))
        }
    }
}
