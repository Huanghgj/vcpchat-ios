import Foundation

/// A message-local projection of the last open, top-level code fence. Stable prose
/// is parsed once. Edits, closing delimiters, changed options and the terminal frame
/// always use the complete source again.
struct StreamFenceTail {
    let prefix: String
    let marker: Character
    let length: Int
    let language: String
    var body: String

    /// Reinspect only the previous unfinished line and the new suffix for a closing fence.
    func appending(_ delta: Substring) -> Self? {
        guard !delta.contains("\r"), !delta.contains("\0") else { return nil }
        let last=body.lastIndex(of:"\n").map { body.index(after:$0) } ?? body.startIndex
        let changed=String(body[last...]) + delta
        for raw in changed.split(separator:"\n",omittingEmptySubsequences:false) {
            let line=raw.drop(while: { $0==" " })
            guard raw.count-line.count <= 3 else { continue }
            let fence=line.prefix(while: { $0==marker })
            if fence.count >= length && line.dropFirst(fence.count).allSatisfy({$0==" " || $0=="\t"}) { return nil }
        }
        var result=self
        result.body.append(contentsOf:delta)
        return result
    }

    static func split(_ source: String) -> Self? {
        // Do not split opaque cards/protocol payloads or Markdown reference definitions.
        guard !source.contains("<"), !source.contains("[---"), !source.contains("]:"),
              source.contains("`") || source.contains("~~~") else { return nil }
        var opened: (String.Index,String.Index,Character,Int,String)?
        var pos=source.startIndex
        while pos < source.endIndex {
            let end=source[pos...].firstIndex(of:"\n") ?? source.endIndex
            let line=source[pos..<end]
            if let first=line.first, first == "`" || first == "~" {
                let run=line.prefix(while:{ $0==first }).count
                if run >= 3 {
                    let info=line.dropFirst(run).trimmingCharacters(in:.whitespacesAndNewlines)
                    if let last=opened {
                        if last.2==first,run>=last.3,info.isEmpty { opened=nil }
                    } else if end != source.endIndex && (first != "`" || !info.contains("`")) {
                        opened=(pos,source.index(after:end),first,run,info.components(separatedBy:.whitespaces).first ?? "")
                    }
                }
            } else if line.first?.isWhitespace == true,
                      line.trimmingCharacters(in:.whitespaces).hasPrefix("```") || line.trimmingCharacters(in:.whitespaces).hasPrefix("~~~") {
                return nil
            }
            if end==source.endIndex { break };pos=source.index(after:end)
        }
        guard let (at,body,mark,n,language)=opened else {return nil}
        return Self(prefix:String(source[..<at]),marker:mark,length:n,language:language,body:String(source[body...]))
    }
}

enum LooseImageTags {
    // Only relax a tag opener; literal Markdown and raw-text domains are copied unchanged.
    private static let tokens = try! NSRegularExpression(pattern: #"(?is)<!--.*?(?:-->|$)|<(script|style|code|pre|textarea)\b(?:\"[^\"]*\"|'[^']*'|[^'\" >]| )*>.*?(?:</\1\s*>|$)|(?m:^[ \t]{4}[^\n]*|^\t[^\n]*)|(`+)(?!`).*?\2(?!`)|(?<!\\)<[ \t]+(?=img\b)"#)
    static func normalize(_ source: String) -> String {
        guard (source.contains("< ") || source.contains("<\t")) && source.localizedCaseInsensitiveContains("img") else { return source }
        return replace(source)
    }
    private static func replace(_ source: String) -> String {
        let raw=source as NSString
        let fences=HTMLIslandPolicy.codeFences(source)
        var out="", start=0, f=0
        for t in tokens.matches(in:source,range:NSRange(location:0,length:raw.length)) {
            while f < fences.count && NSMaxRange(fences[f]) <= t.range.location { f += 1 }
            guard f==fences.count || !NSLocationInRange(t.range.location,fences[f]),
                  raw.substring(with:t.range).range(of:#"^<[ \t]+$"#,options:.regularExpression) != nil else { continue }
            out += raw.substring(with:NSRange(location:start,length:t.range.location-start)) + "<";start=NSMaxRange(t.range)
        }
        return start == 0 ? source : out + raw.substring(from:start)
    }
}
