class User {
  const User({
    this.id,
    this.provider,
    this.email,
    this.name,
    this.avatar,
    this.createdAt,
  });

  final String? id;
  final String? provider;
  final String? email;
  final String? name;
  final String? avatar;
  final DateTime? createdAt;

  factory User.fromSupabase(dynamic sbUser) {
    final Map<String, dynamic>? metadata = sbUser.userMetadata as Map<String, dynamic>?;
    final String? fullName = metadata?['full_name'] as String? ??
        metadata?['name'] as String? ??
        metadata?['user_name'] as String?;
    final String? avatarUrl = metadata?['avatar_url'] as String? ??
        metadata?['picture'] as String?;

    return User(
      id: sbUser.id as String?,
      provider: sbUser.appMetadata?['provider'] as String?,
      email: sbUser.email as String?,
      name: fullName?.trim().isNotEmpty == true ? fullName!.trim() : null,
      avatar: avatarUrl?.trim().isNotEmpty == true ? avatarUrl!.trim() : null,
      createdAt: sbUser.createdAt == null
          ? null
          : DateTime.tryParse(sbUser.createdAt as String),
    );
  }

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      provider: json['provider'],
      email: json['email'],
      name: json['name'],
      avatar: json['avatar'],
      createdAt: json['created_at'] == null
          ? null
          : DateTime.tryParse(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'provider': provider,
      'email': email,
      'name': name,
      'avatar': avatar,
      'created_at': createdAt?.toIso8601String(),
    };
  }
}
