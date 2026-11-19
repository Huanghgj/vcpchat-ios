import Foundation

/// A VCP batch is a transport envelope, not a Markdown block. Its exact ID is
/// opaque (timestamps can contain time zones). Tool output cannot open another batch.
enum ToolBatchMarkup {
    enum Domain { case prose(String), receipt(String, closed: Bool) }
    private static let start = "<<<[VCP_TOOL_BATCH_START:"
    private static let end = "<<<[VCP_TOOL_BATCH_END:"
    private static let user = "<<<[ROLE_DIVIDE_USER]>>>"
    private static let endUser = "<<<[END_ROLE_DIVIDE_USER]>>>"
    private static let tokens = try! NSRegularExpression(pattern: #"(?im)^ {0,3}(`{3,}+|~{3,}+)[^\r\n]*|^(?: {4}|\t)[^\r\n]*|(?<!\\)(`++)|<!--|<(script|style|pre|code|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>|<<<\[TOOL_REQUEST\]>>>|\[\[VCP调用结果信息汇总:|(?<!\\)<<<\[VCP_TOOL_BATCH_(START|END):([^\]\r\n]{1,128})\]>>>"#)
    private static let closingShell = try! NSRegularExpression(pattern: #"\s*<<<\[END_ROLE_DIVIDE_USER\]>>>"#)
    private static let openingShell = try! NSRegularExpression(pattern: #"<<<\[ROLE_DIVIDE_USER\]>>>\s*\z"#)

    /// Suppress a split transport header only at the live edge, not in stored text.
    private static func trimPending(_ raw: String, streaming: Bool) -> String {
        guard streaming, let at = raw.range(of: "<<<[", options: .backwards)?.lowerBound else { return raw }
        let suffix = String(raw[at...])
        guard !suffix.contains("\n"), !suffix.contains("\r"), suffix.utf16.count <= 160 else { return raw }
        if [start,end,user,endUser].contains(where: { $0 != suffix && $0.hasPrefix(suffix) }) ||
            ([start,end].contains(where: { suffix.hasPrefix($0) }) && !suffix.contains("]>>>")) {
            return String(raw[..<at])
        }
        return raw
    }

    static func split(_ raw: String, streaming: Bool) -> [Domain] {
        guard raw.contains("<<<[VCP_TOOL_BATCH_") || (streaming && raw.contains("<<<[")) else { return [.prose(raw)] }
        let text = raw as NSString
        var domains: [Domain] = [], pos = 0, plain = 0, literalTail = false
        func remaining(_ pos: Int) -> NSRange { NSRange(location: pos, length: text.length-pos) }
        func through(_ token: String, from: Int, insensitive: Bool = false) -> Int? {
            let range = text.range(of: token, options: insensitive ? .caseInsensitive : .literal, range: remaining(from))
            return range.location == NSNotFound ? nil : NSMaxRange(range)
        }
        while pos < text.length, let m = tokens.firstMatch(in: raw, options: [.withoutAnchoringBounds,.withTransparentBounds], range: remaining(pos)) {
            pos = NSMaxRange(m.range)
            if m.range(at: 4).location != NSNotFound {
                let isStart = text.substring(with:m.range(at:4)).uppercased() == "START"
                let id = text.substring(with:m.range(at:5))
                var before = text.substring(with:NSRange(location:plain,length:m.range.location-plain))
                if !isStart { // An orphan footer must not consume the text after it.
                    if !before.isEmpty { domains.append(.prose(before)) }
                    plain=pos;continue
                }
                let finish = text.range(of:end+id+"]>>>", options:.literal, range:remaining(pos))
                let closed = finish.location != NSNotFound
                var after = closed ? NSMaxRange(finish) : text.length
                if let shell = openingShell.firstMatch(in:before,range:NSRange(location:0,length:before.utf16.count)) {
                    let closing = closingShell.firstMatch(in:raw, options:.anchored, range:remaining(after))
                    if let closing, closing.range.location==after {
                        before=(before as NSString).substring(to:shell.range.location);after=NSMaxRange(closing.range)
                    } else if streaming && (!closed || trimPending(text.substring(from:after),streaming:true).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) {
                        before=(before as NSString).substring(to:shell.range.location)
                    }
                }
                if !before.isEmpty { domains.append(.prose(before)) }
                let body=text.substring(with:NSRange(location:pos,length:(closed ? finish.location : text.length)-pos))
                domains.append(.receipt(trimPending(body, streaming:streaming && !closed),closed:closed))
                pos=after;plain=after;continue
            }
            let token = text.substring(with:m.range)
            var skip: Int?
            if m.range(at:1).location != NSNotFound {
                let fence=text.substring(with:m.range(at:1)), character=String(fence.prefix(1))
                if let re=try? NSRegularExpression(pattern:"(?m)^ {0,3}"+character+"{"+String(fence.count)+",}[ \\t]*\\r?$"),
                   let close=re.firstMatch(in:raw,options:.withoutAnchoringBounds,range:remaining(pos)) { skip=NSMaxRange(close.range) }
            } else if m.range(at:2).location != NSNotFound {
                let ticks=token.utf16.count
                let re=try? NSRegularExpression(pattern:"(?<!`)`{"+String(ticks)+"}(?!`)")
                if let close=re?.firstMatch(in:raw,options:.withTransparentBounds,range:remaining(pos)) { skip=NSMaxRange(close.range) }
                else { continue } // Unmatched inline backticks are literal punctuation.
            } else if m.range(at:3).location != NSNotFound {
                let tag=text.substring(with:m.range(at:3))
                skip=through("</"+tag+">",from:pos,insensitive:true)
            } else if token=="<!--" { skip=through("-->",from:pos) }
            else if token=="<<<[TOOL_REQUEST]>>>" { skip=through("<<<[END_TOOL_REQUEST]>>>",from:pos) }
            else if token=="[[VCP调用结果信息汇总:" { skip=through("VCP调用结果结束]]",from:pos) }
            else { continue }
            if let skip { pos=skip } else { literalTail=true;break }
        }
        let tail=text.substring(from:plain)
        if !tail.isEmpty { domains.append(.prose(literalTail ? tail : trimPending(tail,streaming:streaming))) }
        return domains
    }
}
