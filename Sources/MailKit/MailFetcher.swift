import Foundation

// Extraction Mail.app via AppleScript, portée du skill `mail-triage` (mail-fetch.swift).
//
// Perf : on récupère `source` (MIME brut, ~50 ms/message) au lieu de `content`
// (~1,9 s/message : Mail décode et rend le HTML). Le corps est décodé côté Swift.
// Mesuré sur 20 messages : content 38 s → source 1 s.
//
// Plafond connu : le filtre `whose date received` doit matérialiser les références depuis la
// boîte ; sur une grosse boîte Exchange (~27 k messages) l'extraction sur 7 jours prend ~1 min 30,
// incompressible au niveau AppleScript. D'où l'exécution hors du MainActor et un statut « ça peut
// prendre une minute » côté UI.

/// Extraction des messages récents de Mail.app.
///
/// ponytail: `NSAppleScript` est sérialisé par l'acteur (une instance, un appel à la fois) ; passer
/// à un helper `osascript` hors-processus seulement si le sandbox l'impose.
public actor MailFetcher {
    public init() {}

    /// Messages reçus sur la période demandée, regroupés par conversation (plus récente en tête).
    /// - Parameters:
    ///   - period: jours calendaires inclusifs (de minuit du premier jour à minuit du lendemain
    ///     du dernier).
    ///   - limit: nombre maximum de messages remontés (garde-fou sur les très grosses boîtes).
    ///   - bodyChars: longueur du corps texte conservée par message après décodage MIME.
    public func fetch(period: MailPeriod, limit: Int = 300, bodyChars: Int = 2000) throws -> MailFetchResult {
        // On récupère assez de source brute pour décoder ~bodyChars de texte visible, tout en
        // bornant le transfert des grosses pièces jointes inline (plafond : ~40 Ko/message).
        let sourceCap = max(bodyChars * 20, 40000)

        // AppleScript renvoie les dates en delta vs son propre `nowd` : capturer l'origine AVANT
        // l'exécution, sinon tout est décalé de la durée du script (~1 min 30). Les bornes de la
        // période sont exprimées dans le même repère.
        let now = Date()
        let bounds = period.bounds()
        guard let script = NSAppleScript(source: Self.script(
            bounds: bounds, now: now, limit: limit, sourceCap: sourceCap))
        else {
            throw MailError.appleScript("script illisible")
        }

        var errInfo: NSDictionary?
        let result = script.executeAndReturnError(&errInfo)
        if let e = errInfo {
            if (e["NSAppleScriptErrorNumber"] as? Int) == -1743 { throw MailError.automationDenied }
            throw MailError.appleScript(
                "\(e["NSAppleScriptErrorNumber"] ?? "?") — \(e["NSAppleScriptErrorMessage"] ?? e)")
        }

        // Parsing du descripteur : listes à positions fixes, voir `script(bounds:now:limit:sourceCap:)`.
        var collected: [MailMessage] = []
        for i in 0..<result.numberOfItems {
            guard let item = result.atIndex(i + 1) else { continue }
            func s(_ j: Int) -> String { item.atIndex(j)?.stringValue ?? "" }
            let id = s(1)
            let urlID = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
            collected.append(MailMessage(
                id: id,
                url: id.isEmpty ? "" : "message://%3C\(urlID)%3E",
                subject: s(2), sender: s(3), to: s(4), cc: s(5),
                date: now.addingTimeInterval(item.atIndex(6)?.doubleValue ?? 0),
                mailbox: s(7),
                isRead: item.atIndex(8)?.booleanValue ?? false,
                flagged: item.atIndex(9)?.booleanValue ?? false,
                attachments: Int(item.atIndex(10)?.int32Value ?? 0),
                body: String(Self.decodeMIME(s(11)).prefix(bodyChars))))
        }

        // Garde-fou : on ne fait confiance qu'aux dates qu'on a nous-mêmes reconstruites, pas au
        // filtre `whose` de Mail (fuseaux, messages sans date reçue).
        let inPeriod = collected.filter { $0.date >= bounds.start && $0.date < bounds.endExclusive }

        return MailFetchResult(
            generatedAt: now, period: period, messageCount: inPeriod.count,
            threads: Self.group(inPeriod))
    }

    // MARK: - Regroupement par conversation

    /// Regroupe par sujet normalisé, conversations les plus récentes en tête, messages du plus
    /// ancien au plus récent à l'intérieur.
    /// ponytail: regroupement par sujet, pas par en-têtes References/In-Reply-To ; passer aux vrais
    /// en-têtes si des conversations distinctes au même sujet posent problème.
    static func group(_ messages: [MailMessage]) -> [MailThread] {
        let sorted = messages.sorted { $0.date > $1.date }
        var order: [String] = []
        var groups: [String: [MailMessage]] = [:]
        for m in sorted {
            let norm = normalizeSubject(m.subject).lowercased()
            let key = norm.isEmpty ? "(sans sujet) \(m.id)" : norm
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.compactMap { key in
            guard let items = groups[key]?.sorted(by: { $0.date < $1.date }), let last = items.last
            else { return nil }
            let subject = normalizeSubject(last.subject)
            return MailThread(subject: subject.isEmpty ? "(sans sujet)" : subject, messages: items)
        }
    }

    /// Retire les préfixes de réponse/transfert cumulés (`Re:`, `TR:`, `Fwd:`…).
    public static func normalizeSubject(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let re = #/(?i)^(?:(?:re|fwd?|tr|aw|rv|r[eé]p)\s*(?:\[\d+\])?\s*:\s*)+/#
        return t.replacing(re, with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Décodage MIME (remplace le `content` lent de Mail)

    static func splitHeaderBody(_ s: String) -> (String, String) {
        if let r = s.range(of: "\r\n\r\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        if let r = s.range(of: "\n\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return (s, "")
    }

    static func parseHeaders(_ h: String) -> [String: String] {
        var out: [String: String] = [:]
        var lastKey: String?
        for line in h.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t", let k = lastKey {          // ligne repliée
                out[k]? += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let idx = line.firstIndex(of: ":") {
                let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                out[key] = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                lastKey = key
            }
        }
        return out
    }

    static func param(_ headerValue: String, _ name: String) -> String? {
        guard let r = headerValue.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = headerValue[r.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            return String(rest[..<(rest.firstIndex(of: "\"") ?? rest.endIndex)])
        }
        return String(rest[..<(rest.firstIndex(where: { $0 == ";" || $0 == " " }) ?? rest.endIndex)])
    }

    static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    static func decodeQP(_ s: String) -> Data {
        let c = Array(s.utf8)                                                        // QP est ASCII
        var out = [UInt8](); out.reserveCapacity(c.count)
        var i = 0
        while i < c.count {
            if c[i] == 0x3D {                                                        // '='
                if i + 1 < c.count, c[i + 1] == 0x0A { i += 2; continue }            // saut mou =\n
                if i + 1 < c.count, c[i + 1] == 0x0D { i += (i + 2 < c.count && c[i + 2] == 0x0A) ? 3 : 2; continue }
                if i + 2 < c.count, let hi = hexNibble(c[i + 1]), let lo = hexNibble(c[i + 2]) {
                    out.append(hi << 4 | lo); i += 3; continue
                }
            }
            out.append(c[i]); i += 1
        }
        return Data(out)
    }

    static func decodeText(_ data: Data, charset: String) -> String {
        let cs = charset.lowercased()
        if cs.contains("1252") || cs.contains("8859") || cs.contains("latin") {
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        for k in 1...3 where data.count > k {                                        // coupé au milieu d'un multi-octets
            if let s = String(data: data.dropLast(k), encoding: .utf8) { return s }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stripHTML(_ s: String) -> String {
        var t = s
        t = t.replacing(#/(?s)<!--.*?-->/#, with: " ")                              // commentaires (peuvent contenir des >)
        t = t.replacing(#/(?is)<head[^>]*>.*?<\/head>/#, with: " ")                 // <title>/<meta> polluaient le preview
        t = t.replacing(#/(?is)<script[^>]*>.*?<\/script>/#, with: " ")
        t = t.replacing(#/(?is)<style[^>]*>.*?<\/style>/#, with: " ")
        t = t.replacing(#/<[^>]+>/#, with: " ")
        t = t.replacing(#/&#(\d+);/#) { m in Unicode.Scalar(UInt32(m.output.1) ?? 0).map { String($0) } ?? " " }
        t = t.replacing(#/&#[xX]([0-9a-fA-F]+);/#) { m in Unicode.Scalar(UInt32(m.output.1, radix: 16) ?? 0).map { String($0) } ?? " " }
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")                        // en dernier
    }

    static func splitParts(_ body: String, boundary: String) -> [String] {
        var parts = body.components(separatedBy: "--" + boundary)
        if !parts.isEmpty { parts.removeFirst() }                                    // préambule
        return parts.compactMap { p in
            if p.hasPrefix("--") { return nil }                                      // frontière de clôture
            // "\r\n" est UN seul Character en Swift : dropFirst(2) mangeait le CRLF *et* la
            // première lettre de l'en-tête suivant ("Content-Type" -> "ontent-type").
            if let f = p.first, f.isNewline { return String(p.dropFirst()) }
            return p
        }
    }

    static func decodePart(headers: [String: String], body: String) -> String {
        let ctypeRaw = headers["content-type"] ?? "text/plain"
        let ctype = ctypeRaw.lowercased()
        if ctype.hasPrefix("multipart/") {
            guard let boundary = param(ctypeRaw, "boundary") else { return "" }
            var fallback = ""
            for part in splitParts(body, boundary: boundary) {
                let (ph, pb) = splitHeaderBody(part)
                let hdr = parseHeaders(ph)
                let decoded = decodePart(headers: hdr, body: pb)
                // Outlook & co. envoient un text/plain vide à côté du vrai HTML : sans le trim,
                // cette partie « non vide » (un simple \r\n) gagne et le corps disparaît.
                if decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if (hdr["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") { return decoded }
                if fallback.isEmpty { fallback = decoded }                           // sinon HTML / imbriqué
            }
            return fallback
        }
        guard ctype.hasPrefix("text/") else { return "" }                           // saute pièces jointes / images
        let enc = (headers["content-transfer-encoding"] ?? "").lowercased()
        let data: Data
        if enc.contains("base64") {
            // `source` est tronquée à sourceCap : le base64 finit souvent au milieu d'un quantum,
            // et Data(base64Encoded:) renvoie nil pour TOUT le corps. On rogne au multiple de 4
            // (no-op sur un base64 complet, qui est toujours padé).
            let clean = body.filter { !$0.isWhitespace }
            data = Data(base64Encoded: String(clean.dropLast(clean.count % 4)),
                        options: .ignoreUnknownCharacters) ?? Data()
        }
        else if enc.contains("quoted-printable") { data = decodeQP(body) }
        else { data = Data(body.utf8) }
        let text = decodeText(data, charset: param(ctypeRaw, "charset") ?? "utf-8")
        return ctype.hasPrefix("text/html") ? stripHTML(text) : text
    }

    /// Source MIME brute → texte lisible, espaces normalisés.
    /// ponytail: décodeur MIME minimal (multipart 1 niveau, QP/base64/7bit, strip HTML,
    /// UTF-8/Latin1). Couvre le mail courant ; si un cas exotique casse l'aperçu, remplacer par un
    /// vrai parseur MIME.
    public static func decodeMIME(_ raw: String) -> String {
        let (h, b) = splitHeaderBody(raw)
        return decodePart(headers: parseHeaders(h), body: b)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - AppleScript

    /// Retourne une liste de listes à positions fixes :
    /// `{message id, subject, sender, to, cc, Δdate, mailbox, read, flagged, nb PJ, source}`.
    ///
    /// Les bornes sont passées en **secondes signées relatives à `now`** : le script les rejoue sur
    /// son propre `current date` (arithmétique de dates AppleScript, pas de littéral date — leur
    /// écriture dépend de la locale du système).
    static func script(bounds: (start: Date, endExclusive: Date), now: Date, limit: Int, sourceCap: Int) -> String {
        let from = Int(bounds.start.timeIntervalSince(now).rounded())
        let to = Int(bounds.endExclusive.timeIntervalSince(now).rounded())
        return """
        on joinList(theList)
            set AppleScript's text item delimiters to ", "
            set s to theList as text
            set AppleScript's text item delimiters to ""
            return s
        end joinList

        with timeout of 600 seconds
            tell application "Mail"
                set nowd to current date
                set startD to nowd + (\(from))
                set endD to nowd + (\(to))
                set msgs to (messages of inbox whose date received >= startD and date received < endD)
                set n to count of msgs
                if n > \(limit) then set n to \(limit)
                set out to {}
                repeat with i from 1 to n
                    set m to item i of msgs
                    set mid to ""
                    try
                        set mid to message id of m
                    end try
                    set subj to ""
                    try
                        set subj to subject of m
                    end try
                    set sndr to ""
                    try
                        set sndr to sender of m
                    end try
                    set toStr to ""
                    try
                        set toStr to my joinList(address of to recipients of m)
                    end try
                    set ccStr to ""
                    try
                        set ccStr to my joinList(address of cc recipients of m)
                    end try
                    set dt to 0
                    try
                        set dt to (date received of m) - nowd
                    end try
                    set mbName to ""
                    try
                        set mb to mailbox of m
                        set mbName to name of mb
                        try
                            set mbName to (name of account of mb) & " — " & mbName
                        end try
                    end try
                    set readVal to false
                    try
                        set readVal to read status of m
                    end try
                    set fl to false
                    try
                        set fl to flagged status of m
                    end try
                    set ac to 0
                    try
                        set ac to count of mail attachments of m
                    end try
                    set src to ""
                    try
                        set src to (source of m) as text
                        if (length of src) > \(sourceCap) then set src to text 1 thru \(sourceCap) of src
                    end try
                    set end of out to {mid, subj, sndr, toStr, ccStr, dt, mbName, readVal, fl, ac, src}
                end repeat
                return out
            end tell
        end timeout
        """
    }
}
