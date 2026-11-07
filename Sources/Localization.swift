import Foundation

enum Lang: String, CaseIterable, Identifiable {
    case en, ko, km, zh
    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: return "English"
        case .ko: return "한국어"
        case .km: return "ខ្មែរ"
        case .zh: return "中文"
        }
    }

    /// Language of the phone's system settings (fallback English)
    static var system: Lang {
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("ko") { return .ko }
        if pref.hasPrefix("km") { return .km }
        if pref.hasPrefix("zh") { return .zh }
        return .en
    }

    /// Language chosen in the app (or system language if never chosen)
    static var current: Lang {
        if let s = UserDefaults.standard.string(forKey: "language"), let l = Lang(rawValue: s) { return l }
        return system
    }
}

func T(_ key: String) -> String {
    guard let row = strings[key] else { return key }
    return row[Lang.current] ?? row[.en] ?? key
}

func TF(_ key: String, _ args: CVarArg...) -> String {
    String(format: T(key), arguments: args)
}

private let strings: [String: [Lang: String]] = {
    var d: [String: [Lang: String]] = [:]
    func a(_ k: String, _ en: String, _ ko: String, _ km: String, _ zh: String) {
        d[k] = [.en: en, .ko: ko, .km: km, .zh: zh]
    }

    // Tabs
    a("tab_transfer", "Transfer", "전송", "ផ្ទេរ", "传输")
    a("tab_connect", "Connect", "연결", "តភ្ជាប់", "连接")
    a("tab_files", "Files", "파일", "ឯកសារ", "文件")
    a("tab_settings", "Settings", "설정", "ការកំណត់", "设置")
    a("nav_transfer", "LAN Transfer", "LAN 전송", "ការផ្ទេរ LAN", "局域网传输")

    // Transfer tab
    a("server_stopped", "Server is stopped", "서버가 중지되었습니다", "ម៉ាស៊ីនមេបានបញ្ឈប់", "服务器已停止")
    a("ready", "Ready to receive", "수신 준비 완료", "ត្រៀមទទួលរួចរាល់", "准备接收")
    a("open_on_pc", "Open on your PC browser or connect from another iPhone",
      "PC 브라우저에서 열거나 다른 iPhone에서 연결하세요",
      "បើកក្នុងកម្មវិធីរុករកលើកុំព្យូទ័រ ឬភ្ជាប់ពី iPhone ផ្សេង",
      "在电脑浏览器中打开，或从另一台 iPhone 连接")
    a("copy_address", "Copy address", "주소 복사", "ចម្លងអាសយដ្ឋាន", "复制地址")
    a("start_server", "Start Server", "서버 시작", "ចាប់ផ្តើមម៉ាស៊ីនមេ", "启动服务器")
    a("stop_server", "Stop Server", "서버 중지", "បញ្ឈប់ម៉ាស៊ីនមេ", "停止服务器")
    a("activity", "Activity", "활동", "សកម្មភាព", "活动")
    a("act_started", "Server started", "서버 시작됨", "ម៉ាស៊ីនមេបានចាប់ផ្តើម", "服务器已启动")
    a("act_stopped", "Server stopped", "서버 중지됨", "ម៉ាស៊ីនមេបានបញ្ឈប់", "服务器已停止")
    a("act_received", "Received %@", "%@ 수신됨", "បានទទួល %@", "已接收 %@")
    a("act_sent", "Sent %@", "%@ 전송됨", "បានផ្ញើ %@", "已发送 %@")
    a("act_deleted", "Deleted %@", "%@ 삭제됨", "បានលុប %@", "已删除 %@")
    a("err_wifi", "Not connected to Wi-Fi?", "Wi-Fi에 연결되어 있지 않나요?", "មិនបានភ្ជាប់ Wi-Fi ទេឬ?", "未连接 Wi-Fi？")
    a("err_start", "Could not start: %@", "시작할 수 없습니다: %@", "មិនអាចចាប់ផ្តើមបាន: %@", "无法启动：%@")
    a("err_server", "Server error: %@", "서버 오류: %@", "កំហុសម៉ាស៊ីនមេ: %@", "服务器错误：%@")

    // Files tab
    a("no_files", "No files yet", "파일이 없습니다", "មិនទាន់មានឯកសារទេ", "暂无文件")
    a("no_files_hint", "Upload from your PC or tap + to add files.",
      "PC에서 업로드하거나 +를 눌러 파일을 추가하세요.",
      "ផ្ទុកឡើងពីកុំព្យូទ័រ ឬចុច + ដើម្បីបន្ថែមឯកសារ។",
      "从电脑上传，或点击 + 添加文件。")

    // Connect tab
    a("nearby", "Nearby iPhones", "주변 iPhone", "iPhone នៅជិត", "附近的 iPhone")
    a("none_found", "No iPhones found. On the other iPhone, tap Start Server.",
      "iPhone을 찾을 수 없습니다. 다른 iPhone에서 서버 시작을 누르세요.",
      "រកមិនឃើញ iPhone ទេ។ នៅលើ iPhone ម្ខាងទៀត សូមចុចចាប់ផ្តើមម៉ាស៊ីនមេ។",
      "未找到 iPhone。请在另一台 iPhone 上点击启动服务器。")
    a("other_ways", "Or connect another way", "다른 방법으로 연결", "ឬភ្ជាប់តាមវិធីផ្សេង", "或使用其他方式连接")
    a("scan_qr", "Scan QR code", "QR 코드 스캔", "ស្កេនកូដ QR", "扫描二维码")
    a("scan_hint", "Point the camera at the QR code on the other iPhone.",
      "다른 iPhone의 QR 코드에 카메라를 향하세요.",
      "ចង្អុលកាមេរ៉ាទៅកូដ QR នៅលើ iPhone ម្ខាងទៀត។",
      "将相机对准另一台 iPhone 上的二维码。")
    a("camera_denied", "Camera access is off. Enable it in Settings.",
      "카메라 접근이 꺼져 있습니다. 설정에서 켜세요.",
      "ការចូលប្រើកាមេរ៉ាត្រូវបានបិទ។ សូមបើកវានៅក្នុងការកំណត់។",
      "相机权限已关闭，请在设置中开启。")
    a("address", "Address (e.g. 192.168.1.23:8080)", "주소 (예: 192.168.1.23:8080)",
      "អាសយដ្ឋាន (ឧ. 192.168.1.23:8080)", "地址（例如 192.168.1.23:8080）")
    a("password_optional", "Password (optional)", "비밀번호(선택)", "ពាក្យសម្ងាត់ (ជម្រើស)", "密码（可选）")
    a("connect", "Connect", "연결", "តភ្ជាប់", "连接")
    a("connecting", "Connecting…", "연결 중…", "កំពុងតភ្ជាប់…", "正在连接…")
    a("connected", "Connected", "연결됨", "បានតភ្ជាប់", "已连接")
    a("disconnect", "Disconnect", "연결 해제", "ផ្តាច់", "断开连接")
    a("send_files", "Send files to this iPhone", "이 iPhone으로 파일 보내기", "ផ្ញើឯកសារទៅ iPhone នេះ", "发送文件到这台 iPhone")
    a("files_on_host", "Files on %@", "%@의 파일", "ឯកសារនៅលើ %@", "%@ 上的文件")
    a("err_connect", "Could not connect. Check the address and Wi-Fi.",
      "연결할 수 없습니다. 주소와 Wi-Fi를 확인하세요.",
      "មិនអាចតភ្ជាប់បានទេ។ សូមពិនិត្យអាសយដ្ឋាន និង Wi-Fi។",
      "无法连接。请检查地址和 Wi-Fi。")
    a("err_password", "Wrong or missing password.", "비밀번호가 없거나 올바르지 않습니다.",
      "ពាក្យសម្ងាត់មិនត្រឹមត្រូវ ឬបាត់។", "密码错误或缺失。")
    a("done", "Done", "완료", "រួចរាល់", "完成")
    a("failed", "Failed", "실패", "បរាជ័យ", "失败")
    a("cancel", "Cancel", "취소", "បោះបង់", "取消")

    // Settings tab
    a("sec_server", "Server", "서버", "ម៉ាស៊ីនមេ", "服务器")
    a("port", "Port: %ld", "포트: %ld", "ច្រក: %ld", "端口：%ld")
    a("keep_awake", "Keep screen awake", "화면 켜진 상태 유지", "រក្សាអេក្រង់ភ្ញាក់", "保持屏幕常亮")
    a("discoverable", "Visible to nearby iPhones", "주변 iPhone에 표시", "បង្ហាញដល់ iPhone នៅជិត", "对附近的 iPhone 可见")
    a("security", "Security", "보안", "សុវត្ថិភាព", "安全")
    a("require_password", "Require password", "비밀번호 필요", "តម្រូវឱ្យមានពាក្យសម្ងាត់", "需要密码")
    a("username", "Username", "사용자 이름", "ឈ្មោះអ្នកប្រើ", "用户名")
    a("password", "Password", "비밀번호", "ពាក្យសម្ងាត់", "密码")
    a("pw_footer", "Your PC browser or the other iPhone will ask for the password.",
      "PC 브라우저나 다른 iPhone에서 비밀번호를 요청합니다.",
      "កម្មវិធីរុករកលើកុំព្យូទ័រ ឬ iPhone ម្ខាងទៀតនឹងសួរពាក្យសម្ងាត់។",
      "电脑浏览器或另一台 iPhone 会要求输入密码。")
    a("storage", "Storage", "저장소", "ទំហំផ្ទុក", "存储")
    a("folder", "Folder", "폴더", "ថត", "文件夹")
    a("folder_path", "On My iPhone › LanTransfer", "내 iPhone › LanTransfer",
      "នៅលើ iPhone របស់ខ្ញុំ › LanTransfer", "我的 iPhone › LanTransfer")
    a("open_files_app", "Open Files app", "파일 앱 열기", "បើកកម្មវិធីឯកសារ", "打开“文件”App")
    a("restart_note", "Stop and start the server to apply changes.",
      "변경 사항을 적용하려면 서버를 중지했다가 다시 시작하세요.",
      "បញ្ឈប់ហើយចាប់ផ្តើមម៉ាស៊ីនមេឡើងវិញ ដើម្បីអនុវត្តការផ្លាស់ប្តូរ។",
      "请停止并重新启动服务器以应用更改。")
    a("language", "Language", "언어", "ភាសា", "语言")
    a("about", "About", "정보", "អំពី", "关于")
    a("version", "Version", "버전", "កំណែ", "版本")
    a("about_text", "Both devices must be on the same Wi-Fi. Transfers are not encrypted, so use a trusted network.",
      "두 기기는 같은 Wi-Fi에 있어야 합니다. 전송은 암호화되지 않으므로 신뢰할 수 있는 네트워크를 사용하세요.",
      "ឧបករណ៍ទាំងពីរត្រូវនៅលើ Wi-Fi តែមួយ។ ការផ្ទេរមិនត្រូវបានអ៊ិនគ្រីបទេ ដូច្នេះសូមប្រើបណ្តាញដែលអាចទុកចិត្តបាន។",
      "两台设备必须在同一 Wi-Fi 下。传输未加密，请使用可信网络。")
    return d
}()
