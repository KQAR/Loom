enum ActionSegment: String, CaseIterable, Identifiable {
    case modifyRequest, replaceRequest, modifyResponse, replaceResponse, redirect
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modifyRequest: return "Modify Req"
        case .replaceRequest: return "Replace Req"
        case .modifyResponse: return "Modify Resp"
        case .replaceResponse: return "Replace Resp"
        case .redirect: return "Redirect"
        }
    }
}
