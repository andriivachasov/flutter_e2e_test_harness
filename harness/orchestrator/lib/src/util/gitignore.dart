/// Minimal .gitignore matcher.
///
/// Used only before `git init`, when `git check-ignore` cannot answer yet but
/// we still must guarantee a secret has a rule covering it. Once the repo
/// exists, git itself is authoritative — do not use this as a substitute.
///
/// Supports the subset that matters here: comments/blanks, `!` negation,
/// trailing-slash directory rules, `*` (within a path segment), `**` (across
/// segments), `?`, anchored patterns (containing `/`) and basename patterns.
library;

/// True when [relativePath] (repo-relative, `/`-separated, no leading `./`)
/// is ignored by [gitignoreContents].
bool isIgnoredByRules(String relativePath, String gitignoreContents) {
  var ignored = false;
  for (final raw in gitignoreContents.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty || line.startsWith('#')) continue;

    final negated = line.startsWith('!');
    var pattern = negated ? line.substring(1) : line;
    if (pattern.isEmpty) continue;

    // A trailing slash restricts the rule to directories; for our purposes
    // "the file lives under that directory" is the useful reading.
    final dirOnly = pattern.endsWith('/');
    if (dirOnly) pattern = pattern.substring(0, pattern.length - 1);

    if (_matches(relativePath, pattern, dirOnly: dirOnly)) {
      ignored = !negated;
    }
  }
  return ignored;
}

bool _matches(String path, String pattern, {required bool dirOnly}) {
  final anchored = pattern.contains('/');
  final normalized = pattern.startsWith('/') ? pattern.substring(1) : pattern;
  final regex = RegExp('^${_globToRegex(normalized)}\$');

  if (anchored) {
    // Match the path itself, or any ancestor directory of it.
    if (regex.hasMatch(path)) return true;
    final segments = path.split('/');
    for (var i = 1; i < segments.length; i++) {
      if (regex.hasMatch(segments.take(i).join('/'))) return true;
    }
    return false;
  }

  // Unanchored: match any single segment (a basename, or a directory in the
  // middle of the path when the rule is directory-only).
  final segments = path.split('/');
  for (var i = 0; i < segments.length; i++) {
    final isLast = i == segments.length - 1;
    if (dirOnly && isLast) continue; // a directory rule can't match the file
    if (regex.hasMatch(segments[i])) return true;
  }
  return false;
}

String _globToRegex(String glob) {
  final out = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        out.write('.*');
        i++;
        // Swallow the slash in `**/`, so it can also match zero directories.
        if (i + 1 < glob.length && glob[i + 1] == '/') i++;
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(c));
    }
  }
  return out.toString();
}
