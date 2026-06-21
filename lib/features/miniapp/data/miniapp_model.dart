class MiniApp {
  const MiniApp({
    required this.id,
    required this.name,
    this.icon,
    required this.codeHtml,
    required this.createdAt,
    this.showOnHome = false,
  });

  final String id;
  final String name;
  final String? icon;
  final String codeHtml;
  final String createdAt;
  final bool showOnHome;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'icon': icon,
      'code_html': codeHtml,
      'created_at': createdAt,
      'show_on_home': showOnHome ? 1 : 0,
    };
  }

  factory MiniApp.fromMap(Map<String, Object?> map) {
    return MiniApp(
      id: map['id'] as String,
      name: map['name'] as String,
      icon: map['icon'] as String?,
      codeHtml: map['code_html'] as String,
      createdAt: map['created_at'] as String,
      showOnHome: (map['show_on_home'] as int? ?? 0) == 1,
    );
  }

  MiniApp copyWith({
    String? id,
    String? name,
    String? icon,
    String? codeHtml,
    String? createdAt,
    bool? showOnHome,
  }) {
    return MiniApp(
      id: id ?? this.id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      codeHtml: codeHtml ?? this.codeHtml,
      createdAt: createdAt ?? this.createdAt,
      showOnHome: showOnHome ?? this.showOnHome,
    );
  }
}
