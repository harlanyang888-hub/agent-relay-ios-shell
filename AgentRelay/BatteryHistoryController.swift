import UIKit

private struct BatteryHistoryPoint {
    let date: Date
    let percent: Int
    let charging: Bool
    let usb: Bool
    let device: String
}

// Presentation of recorded telemetry only; never estimates missing samples.
final class BatteryHistoryController: UIViewController {
    private let range = UISegmentedControl(items: ["6 小时", "24 小时", "7 天"])
    private let chart = BatteryHistoryChart()
    private let summary = UILabel()
    private let selection = UILabel()
    private var points: [BatteryHistoryPoint] = []
    private var loadGeneration = 0
    private let device = WatchBatteryStore.shared.deviceID?.uuidString

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "电量记录"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 10/255, green: 11/255, blue: 13/255, alpha: 1)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(export)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(loadHistory))
        ]
        range.selectedSegmentIndex = 1
        range.addTarget(self, action: #selector(render), for: .valueChanged)
        summary.text = "正在读取记录…"
        let legend = UILabel()
        legend.text = "蓝色：电池供电　绿色：USB / 充电\n点击曲线查看读数；空白表示没有记录。"
        let note = UILabel()
        note.text = "百分比来自手表芯片估算。仅展示实际收到的数据；充电期间的曲线不能用于推算续航。后台暂停、断连或 App 关闭可能造成记录缺口。"
        for label in [summary, selection, legend, note] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
        }
        summary.textColor = .label
        let stack = UIStackView(arrangedSubviews: [range, summary, chart, selection, legend, note])
        stack.axis = .vertical; stack.spacing = 20
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            chart.heightAnchor.constraint(equalToConstant: 280)
        ])
        chart.onSelect = { [weak self] point in
            let format = DateFormatter(); format.dateFormat = "MM-dd HH:mm:ss"
            self?.selection.text = "\(format.string(from: point.date)) · \(point.percent)% · \(point.charging ? "充电中" : point.usb ? "USB 已连接" : "电池供电")"
        }
        loadHistory()
    }

    @objc private func loadHistory() {
        guard let url = WatchBatteryStore.shared.historyURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let format = ISO8601DateFormatter()
            var loaded: [BatteryHistoryPoint] = []
            var failure: String?
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    for line in text.split(separator: "\n") {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              object["valid"] as? Bool == true, object["batteryPresent"] as? Bool == true,
                              let at = object["at"] as? String, let date = format.date(from: at),
                              let percent = object["percent"] as? Int, (0...100).contains(percent),
                              let device = object["device"] as? String else { continue }
                        loaded.append(BatteryHistoryPoint(date: date, percent: percent,
                            charging: object["charging"] as? Bool ?? false, usb: object["usb"] as? Bool ?? false, device: device))
                    }
                }
            } catch { failure = "暂时无法读取电量记录，请稍后刷新。" }
            let result = loaded.sorted { $0.date < $1.date }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, generation == self.loadGeneration else { return }
                self.points = result
                self.render()
                if let failure = failure { self.summary.text = failure }
            }
        }
    }
    @objc private func render() {
        let hours = [6.0, 24.0, 168.0][range.selectedSegmentIndex]
        let end = Date(), start = end.addingTimeInterval(-hours * 3600)
        // Never join telemetry from different devices into one curve.
        let selectedDevice = device ?? points.last?.device
        let visible = points.filter { $0.date >= start && $0.date <= end && $0.device == selectedDevice }
        // Fit the available history so a new installation's few minutes of
        // readings do not collapse into a single pixel on a 24-hour axis.
        let plotStart = visible.first.map { max(start, $0.date.addingTimeInterval(-60)) } ?? start
        chart.update(visible, start: plotStart, end: end)
        selection.text = visible.isEmpty ? "连接 relay watch 后会自动积累电量记录。" : "轻点一个数据点，查看时间和电量。"
        if let first = visible.first, let last = visible.last {
            summary.text = "\(first.percent)% → \(last.percent)%　·　\(visible.count) 条有效记录"
        } else { summary.text = "这个时间范围内暂无有效记录" }
    }
    @objc private func export() {
        guard let url = WatchBatteryStore.shared.historyURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }
}

private final class BatteryHistoryChart: UIView {
    private var points: [BatteryHistoryPoint] = []
    private var start = Date(), end = Date()
    private var selected: Int?
    var onSelect: ((BatteryHistoryPoint) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 24/255, alpha: 1)
        layer.cornerRadius = 18
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectPoint(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ points: [BatteryHistoryPoint], start: Date, end: Date) {
        self.points = points; self.start = start; self.end = end; selected = nil
        accessibilityLabel = "电量曲线，\(points.count) 条记录"
        accessibilityValue = points.last.map { "最新电量 \($0.percent)%" } ?? "暂无数据"
        setNeedsDisplay()
    }
    private var plot: CGRect { CGRect(x: 40, y: 24, width: max(1, bounds.width - 56), height: max(1, bounds.height - 66)) }
    private func position(_ point: BatteryHistoryPoint) -> CGPoint {
        CGPoint(x: plot.minX + CGFloat(point.date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))) * plot.width,
                y: plot.maxY - CGFloat(point.percent) / 100 * plot.height)
    }
    private func label(_ text: String, at point: CGPoint) {
        (text as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.secondaryLabel])
    }
    override func draw(_ rect: CGRect) {
        for level in [0, 50, 100] {
            let y = plot.maxY - CGFloat(level) / 100 * plot.height
            let line = UIBezierPath(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
            UIColor.white.withAlphaComponent(0.08).setStroke(); line.stroke()
            label("\(level)%", at: CGPoint(x: 5, y: y - 7))
        }
        let format = DateFormatter(); format.dateFormat = end.timeIntervalSince(start) > 86400 ? "MM-dd" : "HH:mm"
        label(format.string(from: start), at: CGPoint(x: plot.minX, y: plot.maxY + 14))
        label(format.string(from: end), at: CGPoint(x: plot.maxX - 34, y: plot.maxY + 14))
        guard !points.isEmpty else {
            label("暂无电量数据", at: CGPoint(x: plot.midX - 36, y: plot.midY)); return
        }
        for (index, point) in points.enumerated() {
            let color: UIColor = point.usb || point.charging ? .systemGreen : .systemCyan
            color.setStroke(); color.setFill()
            let p = position(point)
            if index > 0 {
                let previous = points[index - 1]
                // Gaps remain visible; no fabricated readings or smooth interpolation.
                if point.date.timeIntervalSince(previous.date) <= 300 {
                    let line = UIBezierPath(); line.lineWidth = 2
                    line.move(to: position(previous)); line.addLine(to: p); line.stroke()
                }
            }
            UIBezierPath(ovalIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
        }
        if let index = selected, points.indices.contains(index) {
            let p = position(points[index]); UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)); ring.lineWidth = 2; ring.stroke()
        }
    }
    @objc private func selectPoint(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: self).x
        guard let index = points.indices.min(by: { abs(position(points[$0]).x - x) < abs(position(points[$1]).x - x) }) else { return }
        selected = index; onSelect?(points[index]); setNeedsDisplay()
    }
}
