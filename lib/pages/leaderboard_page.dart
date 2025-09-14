import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key});
  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  User? get _user => _auth.currentUser;

  List<List<T>> _chunk<T>(List<T> items, int size) {
    if (items.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += size) {
      chunks.add(items.sublist(i, i + size > items.length ? items.length : i + size));
    }
    return chunks;
  }

  Future<List<_Entry>> _fetchRankedFriends(List<String> friendUids) async {
    if (friendUids.isEmpty) return const [];

    // Firestore whereIn limit = 10 → chunk and merge
    final chunks = _chunk(friendUids, 10);
    final allDocs = <DocumentSnapshot<Map<String, dynamic>>>[];

    for (final c in chunks) {
      final snap = await _db
          .collection('users')
          .where(FieldPath.documentId, whereIn: c)
          .get();
      allDocs.addAll(snap.docs);
    }

    final entries = <_Entry>[];
    for (final d in allDocs) {
      final data = d.data();
      if (data == null) continue;
      entries.add(_Entry(
        uid: d.id,
        name: (data['displayName'] ?? data['email'] ?? 'Unknown') as String,
        xp: (data['xp'] ?? 0) as int,
        photoURL: (data['photoURL'] ?? '') as String,
      ));
    }

    entries.sort((a, b) => b.xp.compareTo(a.xp)); // rank by XP desc
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final me = _user;
    if (me == null) {
      return const Scaffold(body: Center(child: Text('Not logged in')));
    }

    final friendsStream = _db
        .collection('users')
        .doc(me.uid)
        .collection('friends') // 👈 each docId should be the friend's UID
        .snapshots();

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: friendsStream,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          // Collect friend UIDs (doc.id or fallback to field 'uid')
          final friendIds = <String>[];
          for (final doc in (snap.data?.docs ?? const [])) {
            final id = doc.id;
            if (id.isNotEmpty) {
              friendIds.add(id);
            } else {
              final m = doc.data();
              final fallback = (m['uid'] ?? '') as String;
              if (fallback.isNotEmpty) friendIds.add(fallback);
            }
          }

          if (friendIds.isEmpty) {
            return const Center(child: Text('No friends yet'));
          }

          // Fetch friend profiles (XP, name) and rank on the client
          return FutureBuilder<List<_Entry>>(
            future: _fetchRankedFriends(friendIds),
            builder: (context, fb) {
              if (fb.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (fb.hasError) {
                return Center(child: Text('Error: ${fb.error}'));
              }
              final rows = fb.data ?? const [];
              if (rows.isEmpty) {
                return const Center(child: Text('No friends found'));
              }

              return RefreshIndicator(
                onRefresh: () async => setState(() {}),
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text('${i + 1}'),
                        foregroundImage: (r.photoURL.isNotEmpty)
                            ? NetworkImage(r.photoURL)
                            : null,
                      ),
                      title: Text(r.name),
                      trailing: Text('${r.xp} XP'),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Entry {
  final String uid;
  final String name;
  final int xp;
  final String photoURL;
  _Entry({required this.uid, required this.name, required this.xp, required this.photoURL});
}
