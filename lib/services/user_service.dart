import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  UserService._();
  static final instance = UserService._();

  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;

  /// Create or merge users/{uid} WITHOUT clobbering partner fields.
  Future<void> ensureUserDoc() async {
    final u = currentUser;
    if (u == null) return;

    final ref = _db.collection('users').doc(u.uid);
    final snap = await ref.get();

    if (!snap.exists) {
      await ref.set({
        'email': u.email ?? '',
        'emailLower': (u.email ?? '').toLowerCase(),
        'displayName': u.displayName ?? '',
        'photoURL': u.photoURL ?? '',
        'xp': 0,
        'level': 1,
        'partnerLinked': false,
        'partnerUid': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } else {
      // Update safe identity fields only
      await ref.set({
        'email': u.email ?? '',
        'emailLower': (u.email ?? '').toLowerCase(),
        'displayName': u.displayName ?? '',
        'photoURL': u.photoURL ?? '',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  /// Stream my user doc.
  Stream<DocumentSnapshot<Map<String, dynamic>>>? userDocStream() {
    final uid = currentUser?.uid;
    if (uid == null) return null;
    return _db.collection('users').doc(uid).snapshots();
  }

  /// Find a user by email (case-insensitive) or username/userName.
  Future<String?> findUserIdByIdentifier(String input) async {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    if (raw.contains('@')) {
      final byEmail = await _db
          .collection('users')
          .where('emailLower', isEqualTo: raw.toLowerCase())
          .limit(1)
          .get();
      if (byEmail.docs.isNotEmpty) return byEmail.docs.first.id;
    } else {
      final byUsername = await _db
          .collection('users')
          .where('username', isEqualTo: raw)
          .limit(1)
          .get();
      if (byUsername.docs.isNotEmpty) return byUsername.docs.first.id;

      final byUserName = await _db
          .collection('users')
          .where('userName', isEqualTo: raw)
          .limit(1)
          .get();
      if (byUserName.docs.isNotEmpty) return byUserName.docs.first.id;
    }
    return null;
  }

  /// Create/merge a partner request between me and `toUid`.
  Future<void> sendPartnerRequest(String toUid) async {
    final me = currentUser;
    if (me == null) throw Exception('Not signed in');
    if (toUid == me.uid) throw Exception('Cannot link yourself');

    final pairKey = [me.uid, toUid]..sort();
    final reqId = '${pairKey[0]}__${pairKey[1]}';

    final reqRef = _db.collection('partner_requests').doc(reqId);
    await reqRef.set({
      'fromUid': me.uid,
      'toUid': toUid,
      'status': 'pending', // 'accepted' | 'declined'
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Stream of my incoming pending partner requests.
  Stream<QuerySnapshot<Map<String, dynamic>>>? incomingRequests() {
    final me = currentUser;
    if (me == null) return null;
    return _db
        .collection('partner_requests')
        .where('toUid', isEqualTo: me.uid)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  /// Accept a request:
  /// - link both users (partnerLinked=true, partnerUid=other)
  /// - mark request accepted
  /// - create friend edges: users/A/friends/B and users/B/friends/A
  Future<void> acceptRequest({
    required String requestId,
    required String fromUid,
  }) async {
    final me = currentUser;
    if (me == null) throw Exception('Not signed in');

    await _db.runTransaction((tx) async {
      final meRef = _db.collection('users').doc(me.uid);
      final otherRef = _db.collection('users').doc(fromUid);
      final reqRef = _db.collection('partner_requests').doc(requestId);

      // Link both directions
      tx.update(meRef, {'partnerLinked': true, 'partnerUid': fromUid});
      tx.update(otherRef, {'partnerLinked': true, 'partnerUid': me.uid});

      // Mark request
      tx.update(reqRef, {
        'status': 'accepted',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Friend edges (empty doc with createdAt)
      final meFriend = meRef.collection('friends').doc(fromUid);
      final otherFriend = otherRef.collection('friends').doc(me.uid);
      tx.set(meFriend, {'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      tx.set(otherFriend, {'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    });
  }

  /// Decline a request.
  Future<void> declineRequest({required String requestId}) async {
    await _db.collection('partner_requests').doc(requestId).update({
      'status': 'declined',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
