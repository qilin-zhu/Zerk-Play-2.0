import 'pinyin_initial_table.dart';

/// Pinyin-initial matching, shared by every search box in the app.
///
/// Emby answers `bbjx` on its own (verified against a real server), trimemedia
/// does not: it matches whole Chinese tokens, so `bbjx`, `bubu` and even the
/// partial word `步步` come back empty on 飞牛影视. Those have to be matched
/// here, against the titles themselves.

/// What an IME or a remote keyboard leaves between pinyin syllables
/// (`bu'bu'jing'x`), plus the dots and back-quotes some layouts use.
final _noise = RegExp("[’‘`´'·・]");

/// The text that should actually be sent to a server: the separators dropped
/// (they make a server-side match impossible) and runs of spaces collapsed.
String cleanQuery(String raw) => raw.replaceAll(_noise, '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Letters and digits only, lowercased — the shape a pinyin query takes after
/// an IME has been typing into it.
String pinyinKey(String value) {
  final out = StringBuffer();
  for (final r in value.toLowerCase().runes) {
    if ((r >= 0x61 && r <= 0x7a) || (r >= 0x30 && r <= 0x39)) out.writeCharCode(r);
  }
  return out.toString();
}

/// First pinyin letter of every character: `步步惊心` -> `bbjx`.
///
/// Latin letters and digits are kept as they are, so a mixed title such as
/// `爱情公寓 Love` yields `aqgylove` and can be found either way.
String initialsOf(String title) {
  final out = StringBuffer();
  for (final r in title.runes) {
    if (r >= 0x4e00 && r <= 0x9fff) {
      out.writeCharCode(pinyinInitialTable.codeUnitAt(r - 0x4e00));
    } else if (r >= 0x30 && r <= 0x39) {
      out.writeCharCode(r);
    } else if (r >= 0x41 && r <= 0x5a) {
      out.writeCharCode(r + 32);
    } else if (r >= 0x61 && r <= 0x7a) {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

/// Everything a query may legitimately match in one string, precomputed once
/// per title: the initials first, then the plain letters.
///
/// A title matches when either contains the query — `bbjx` hits the initials,
/// `love` hits the letters, and a query with a typo in the middle of a pinyin
/// string still lands on the letters half.
final class TitleKey {
  TitleKey(String title)
      : initials = initialsOf(title),
        letters = pinyinKey(title);

  final String initials;
  final String letters;

  /// 0 = no match, 1 = a title that starts with the query, 2 = one that has it
  /// somewhere inside. Used to put the most likely hit first.
  int rank(String query) {
    if (query.isEmpty) return 0;
    if (initials.startsWith(query) || letters.startsWith(query)) return 1;
    if (initials.contains(query) || letters.contains(query)) return 2;
    return 0;
  }
}
