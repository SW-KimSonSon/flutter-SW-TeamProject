/// Immutable source snapshot. Future repositories can supply their lecture ID.
class LectureContext {
  const LectureContext({required this.transcript, this.lectureId});

  final String transcript;
  final String? lectureId;
}

enum LectureAiKind { summary, answer }

/// The caller decides whether to display, persist, or turn this into a PKM note.
/// No database or Flutter dependency belongs in this value object.
class LectureAiResult {
  const LectureAiResult({
    required this.kind,
    required this.content,
    required this.source,
    required this.model,
    required this.createdAt,
    this.question,
    this.promptVersion = '1',
  });

  final LectureAiKind kind;
  final String content;
  final LectureContext source;
  final String model;
  final DateTime createdAt;
  final String? question;
  final String promptVersion;
}
