import Foundation
import Network
import SystemConfiguration
import CFNetwork

enum HealthLevel { case good, warning, failed, info }
struct HealthCheck {
    let title: String
    let level: HealthLevel
    let detail: String
}
struct NetworkHealthResult {
    let host: String
    var checks: [HealthCheck] = []
    var cancelled = false
    var summary: String {
        if cancelled { return "已取消检查" }
        if checks.contains(where: { $0.level == .failed }) { return "发现需要排查的项目" }
        if checks.contains(where: { $0.level == .warning }) { return "部分项目需要留意" }
        return "本次目标检查通过"
    }
    var report: String {
        "\(summary)\n目标：\(host)\n" + checks.map { "\($0.title)：\($0.detail)" }.joined(separator: "\n\n") +
        "\n\n单个目标不代表整个互联网。耗时包含解析、代理和握手，不是网速；代理 / VPN 可能影响请求路径。工具不修改任何网络配置。"
    }
}
final class HealthValue<T> {
    private let lock = NSLock()
    private var storage: T?
    func set(_ value: T) { lock.lock(); storage = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return storage }
}
final class HealthSessionDelegate: NSObject, URLSessionTaskDelegate {
    // Keep the probe on the explicitly displayed target, without following an unexpected redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct NetworkHealthServices {
    var path: (DiskCancellation) -> HealthCheck
    var configuration: () -> [HealthCheck]
    var dns: (String) -> HealthCheck
    var https: (String, DiskCancellation) -> HealthCheck
    static var live: NetworkHealthServices {
        NetworkHealthServices(path: NetworkHealth.path, configuration: NetworkHealth.configuration,
                              dns: NetworkHealth.dns, https: { host, token in
            NetworkHealth.https(URL(string: "https://\(host)/")!, cancellation: token)
        })
    }
}
enum NetworkHealth {
    static func host(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty, text.utf8.count <= 253, text.unicodeScalars.allSatisfy({ permitted.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            throw DiskError.message("请输入域名，例如 www.apple.com；不包含网址前缀、路径、账号或端口。")
        }
        return text
    }
    static func wait(_ signal: DispatchSemaphore, seconds: TimeInterval, cancellation: DiskCancellation) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
            if signal.wait(timeout: .now() + 0.05) == .success { return true }
        }
        return false
    }
    static func run(_ input: String, cancellation: DiskCancellation, services: NetworkHealthServices = .live,
                    progress: (String) -> Void = { _ in }) throws -> NetworkHealthResult {
        let target = try host(input)
        var result = NetworkHealthResult(host: target)
        guard !cancellation.cancelled else { result.cancelled = true; return result }
        progress("检查本地连接…"); result.checks.append(services.path(cancellation))
        if cancellation.cancelled { result.cancelled = true; return result }
        result.checks.append(contentsOf: services.configuration())
        progress("通过系统解析器检查 DNS…"); result.checks.append(services.dns(target))
        if cancellation.cancelled { result.cancelled = true; return result }
        progress("检查目标 HTTPS 连通性…"); result.checks.append(services.https(target, cancellation))
        result.cancelled = cancellation.cancelled; return result
    }
    static func path(_ cancellation: DiskCancellation) -> HealthCheck {
        let monitor = NWPathMonitor(), signal = DispatchSemaphore(value: 0), value = HealthValue<HealthCheck>()
        monitor.pathUpdateHandler = { path in
            let names = Set(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name)).sorted().joined(separator: "、")
            let good = path.status == .satisfied
            value.set(HealthCheck(title: "本地连接", level: good ? .good : .failed,
                detail: good ? "系统路径可用 · \(names.isEmpty ? "接口由系统管理" : names)；仍需检查目标网站。" :
                    "系统当前没有可直接使用的网络路径。检查 Wi-Fi / 网线及 VPN 是否连接。"))
            signal.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.hb.macpulse.network.path"))
        defer { monitor.cancel() }
        guard wait(signal, seconds: 2, cancellation: cancellation), let result = value.value else {
            return HealthCheck(title: "本地连接", level: .warning, detail: "未能及时取得系统路径状态；不据此判定断网。")
        }
        return result
    }
    static func configuration() -> [HealthCheck] {
        let dns = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        let servers = (dns?["ServerAddresses"] as? [String] ?? []).prefix(8).joined(separator: "、")
        let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        let names = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"),
                     ("ProxyAutoConfigEnable", "PAC"), ("ProxyAutoDiscoveryEnable", "自动发现")]
            .filter { (proxy[$0.0] as? NSNumber)?.boolValue == true }.map { $0.1 }
        return [
            HealthCheck(title: "DNS 配置", level: .info, detail: servers.isEmpty ?
                "系统未公开全局 DNS 地址，可能由 VPN / 加密 DNS 或接口专用解析器管理；以下实际解析结果更有参考价值。" : "系统全局 DNS：\(servers)；可能还存在接口专用解析器。"),
            HealthCheck(title: "系统代理", level: .info, detail: names.isEmpty ?
                "未发现启用的全局 HTTP / HTTPS / SOCKS / PAC 配置；TUN 或应用内部代理仍可能存在。" :
                "已配置：\(names.joined(separator: "、"))。请求可能经过代理；开启代理本身不表示异常。")
        ]
    }
    static func dns(_ host: String) -> HealthCheck {
        var address = [CChar](repeating: 0, count: 128), error: Int32 = 0
        let began = ProcessInfo.processInfo.systemUptime
        let status = mp_resolve_host(host, 3000, &address, Int32(address.count), &error)
        let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
        if status == 1 {
            return HealthCheck(title: "DNS 解析", level: .good, detail: "\(host) → \(String(cString: address)) · \(ms) ms（可能命中系统缓存）")
        }
        return HealthCheck(title: "DNS 解析", level: .failed, detail: status == 0 ?
            "3 秒内未取得目标地址。检查连接 / DNS / VPN，并换一个目标复测。" :
            "系统解析器未能返回目标地址（代码 \(error)）。可能是域名、DNS 或访问策略问题，不能单凭此项认定网络整体故障。")
    }
    static func httpResult(_ response: HTTPURLResponse?, error: Error?, elapsed: TimeInterval) -> HealthCheck {
        if let error = error as NSError? {
            let hint: String
            switch error.code {
            case NSURLErrorTimedOut: hint = "请求超时；检查目标是否可达、代理 / VPN 及当前网络。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: hint = "请求报告域名解析失败；检查域名与系统 DNS，代理也可能影响解析路径。"
            case NSURLErrorNotConnectedToInternet: hint = "请求报告当前离线；检查 Wi-Fi / 网线 / VPN。"
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                hint = "TLS / 证书验证未通过；检查系统时间、目标证书及代理。工具不会绕过证书校验。"
            case NSURLErrorCancelled: hint = "请求已取消。"
            default: hint = "请求未完成；换目标复测，并检查代理 / VPN 与网络连接。"
            }
            return HealthCheck(title: "HTTPS 连通", level: .failed, detail: "\(hint)（\(error.domain)/\(error.code)）")
        }
        guard let response = response else { return HealthCheck(title: "HTTPS 连通", level: .warning, detail: "未取得可判读的 HTTP 响应。") }
        let ok = (200..<300).contains(response.statusCode)
        return HealthCheck(title: "HTTPS 连通", level: ok ? .good : .warning,
            detail: "HTTP \(response.statusCode) · 总耗时 \(Int(elapsed * 1000)) ms。" +
                (ok ? "目标请求成功；此值不是网速。" : "已收到服务器响应，但目标返回了重定向 / 限制或错误；不据此判定整台电脑断网。"))
    }
    static func https(_ url: URL, cancellation: DiskCancellation, configuration: URLSessionConfiguration = .ephemeral,
                      timeout: TimeInterval = 8) -> HealthCheck {
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            return HealthCheck(title: "HTTPS 连通", level: .failed, detail: "检测目标必须使用不带账号的 HTTPS 地址。")
        }
        configuration.timeoutIntervalForRequest = min(5, timeout); configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false; configuration.urlCache = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: HealthSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(5, timeout))
        request.httpMethod = "HEAD"
        let value = HealthValue<HealthCheck>(), signal = DispatchSemaphore(value: 0), began = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request) { _, response, error in
            value.set(httpResult(response as? HTTPURLResponse, error: error, elapsed: ProcessInfo.processInfo.systemUptime - began))
            signal.signal()
        }
        guard !cancellation.cancelled else { return httpResult(nil, error: URLError(.cancelled), elapsed: 0) }
        task.resume()
        guard wait(signal, seconds: timeout + 0.2, cancellation: cancellation), let result = value.value else {
            task.cancel()
            return httpResult(nil, error: URLError(cancellation.cancelled ? .cancelled : .timedOut), elapsed: timeout)
        }
        return result
    }
}
