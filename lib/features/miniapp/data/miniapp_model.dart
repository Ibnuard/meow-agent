class MiniApp {
  const MiniApp({
    required this.id,
    required this.name,
    this.icon,
    required this.codeHtml,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String? icon;
  final String codeHtml;
  final String createdAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
      'code_html': codeHtml,
      'created_at': createdAt,
    };
  }

  factory MiniApp.fromMap(Map<String, Object?> map) {
    return MiniApp(
      id: map['id'] as String,
      name: map['name'] as String,
      icon: map['icon'] as String?,
      codeHtml: map['code_html'] as String,
      createdAt: map['created_at'] as String,
    );
  }
}
