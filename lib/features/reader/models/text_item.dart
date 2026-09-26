class TextItem {
  final String text;
  final String statusClass;
  final int? wordId;
  final int sentenceId;
  final int paragraphId;
  final bool isStartOfSentence;
  final int order;
  final int? langId;

  TextItem({
    required this.text,
    required this.statusClass,
    this.wordId,
    required this.sentenceId,
    required this.paragraphId,
    required this.isStartOfSentence,
    required this.order,
    this.langId,
  });

  TextItem copyWith({
    String? text,
    String? statusClass,
    int? wordId,
    int? sentenceId,
    int? paragraphId,
    bool? isStartOfSentence,
    int? order,
    int? langId,
  }) {
    return TextItem(
      text: text ?? this.text,
      statusClass: statusClass ?? this.statusClass,
      wordId: wordId ?? this.wordId,
      sentenceId: sentenceId ?? this.sentenceId,
      paragraphId: paragraphId ?? this.paragraphId,
      isStartOfSentence: isStartOfSentence ?? this.isStartOfSentence,
      order: order ?? this.order,
      langId: langId ?? this.langId,
    );
  }

  bool get isKnown => statusClass == 'status99';
  bool get isUnknown => statusClass == 'status0';
  bool get isWord => wordId != null;
  bool get isSpace => text.trim().isEmpty;

  /// 显示用文本：剥掉词元里的零宽空格（U+200B，Lute 建词/导入时常混入）。
  ///
  /// 只用于渲染。正文是拉丁字体，日文和 ZWS 走不同的回退字体；带 ZWS 的词
  /// 会被拆成多个字体 run，行盒底部多出几像素——整句播放高亮逐词拼色块时
  /// 底边就参差凸起。剥离后行高恢复一致。回传服务端的载荷（多词选中建词、
  /// TTS 朗读等）仍用原 [text]，与 web 端行为一致。
  String get displayText => text.replaceAll('\u200B', '');

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'statusClass': statusClass,
      'wordId': wordId,
      'sentenceId': sentenceId,
      'paragraphId': paragraphId,
      'isStartOfSentence': isStartOfSentence,
      'order': order,
      'langId': langId,
    };
  }

  factory TextItem.fromJson(Map<String, dynamic> json) {
    return TextItem(
      text: json['text'] as String,
      statusClass: json['statusClass'] as String,
      wordId: json['wordId'] as int?,
      sentenceId: json['sentenceId'] as int,
      paragraphId: json['paragraphId'] as int,
      isStartOfSentence: json['isStartOfSentence'] as bool,
      order: json['order'] as int,
      langId: json['langId'] as int?,
    );
  }
}
