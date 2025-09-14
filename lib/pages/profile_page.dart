import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/user_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _svc = UserService.instance;
  final _partnerCtrl = TextEditingController();
  bool _ensuring = false;
  bool _sending = false;

  // Auto-popup for new incoming requests
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _incomingSub;
  final Set<String> _shownDialogs = {};

  @override
  void initState() {
    super.initState();
    _selfHeal();
    _listenForIncomingPopups();
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _partnerCtrl.dispose();
    super.dispose();
  }

  Future<void> _selfHeal() async {
    setState(() => _ensuring = true);
    try {
      await _svc.ensureUserDoc();
    } finally {
      if (mounted) setState(() => _ensuring = false);
    }
  }

  void _listenForIncomingPopups() {
    final s = _incoming;
    _incomingSub = s?.listen((qs) {
      for (final doc in qs.docs) {
        final id = doc.id;
        if (_shownDialogs.contains(id)) continue; // avoid duplicates
        _shownDialogs.add(id);

        final data = doc.data();
        final fromUid = (data['fromUid'] ?? '') as String;

        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false, // must choose
          builder: (_) => AlertDialog(
            title: const Text('Partnerskap'),
            content: Text('Bruker $fromUid vil koble seg til deg. Godta?'),
            actions: [
              TextButton(
                onPressed: () async {
                  try {
                    await _svc.declineRequest(requestId: id);
                    if (mounted) Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Kunne ikke avslå: $e')),
                    );
                  }
                },
                child: const Text('Avslå'),
              ),
              ElevatedButton(
                onPressed: () async {
                  try {
                    await _svc.acceptRequest(requestId: id, fromUid: fromUid);
                    if (mounted) Navigator.pop(context);
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Kunne ikke akseptere: $e')),
                    );
                    // dialog stays open so user can try again
                  }
                },
                child: const Text('Aksepter'),
              ),
            ],
          ),
        );
      }
    });
  }

  Future<void> _sendPartner() async {
    if (_sending) return;
    final messenger = ScaffoldMessenger.of(context);
    final raw = _partnerCtrl.text.trim();
    if (raw.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Skriv inn e-post eller brukernavn')));
      return;
    }

    setState(() => _sending = true);
    try {
      final me = _svc.currentUser;
      if (me == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Not signed in')));
        return;
      }

      // 1) Lookup
      String? toUid;
      try {
        toUid = await _svc.findUserIdByIdentifier(raw);
      } on FirebaseException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Lookup failed: ${e.message}')));
        return;
      }
      if (toUid == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Fant ingen bruker')));
        return;
      }
      if (toUid == me.uid) {
        messenger.showSnackBar(const SnackBar(content: Text('Du kan ikke linke deg selv')));
        return;
      }

      // 2) Write
      try {
        await _svc.sendPartnerRequest(toUid);
      } on FirebaseException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Write failed: ${e.message}')));
        return;
      }

      messenger.showSnackBar(const SnackBar(content: Text('Forespørsel sendt ✅')));
      _partnerCtrl.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>>? get _userStream =>
      _svc.userDocStream();

  Stream<QuerySnapshot<Map<String, dynamic>>>? get _incoming =>
      _svc.incomingRequests();

  @override
  Widget build(BuildContext context) {
    final user = _svc.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Not logged in')));
    }

    final stream = _userStream;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Stack(
        children: [
          if (stream == null)
            const Center(child: Text('Loading...'))
          else
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Firestore error: ${snap.error}',
                          textAlign: TextAlign.center),
                    ),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snap.hasData || !snap.data!.exists) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Fant ikke brukerdata (users/{uid}).'),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: _selfHeal,
                            child: const Text('Opprett brukerdokument nå'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final data = snap.data!.data() ?? {};
                final photoUrl = (data['photoURL'] ?? data['photoUrl']) as String?;
                final name = (data['displayName'] ?? data['name'] ?? '') as String? ?? '';
                final email = (data['email'] ?? user.email ?? '') as String? ?? '';
                final xp = (data['xp'] ?? 0) as num;
                final level = (data['level'] ?? 1) as num;
                final partnerUid = data['partnerUid'] as String?;
                final partnerLinked = (data['partnerLinked'] ?? false) as bool? ?? false;

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Header
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 36,
                          backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                              ? NetworkImage(photoUrl)
                              : null,
                          child: (photoUrl == null || photoUrl.isEmpty)
                              ? const Icon(Icons.person, size: 36)
                              : null,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name.isEmpty ? 'Uten navn' : name,
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(email, style: const TextStyle(color: Colors.grey)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 12,
                                children: [
                                  Chip(label: Text('XP: $xp')),
                                  Chip(label: Text('Level: $level')),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Partner status
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(Icons.favorite_outline),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                partnerLinked && partnerUid != null
                                    ? 'Koblet til partner ✅'
                                    : 'Ingen partner koblet',
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                final messenger = ScaffoldMessenger.of(context);
                                final msg = partnerLinked && partnerUid != null
                                    ? 'Du er koblet til: $partnerUid'
                                    : 'Du er ikke koblet til noen enda';
                                messenger.showSnackBar(SnackBar(content: Text(msg)));
                              },
                              child: const Text('Se status'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Add partner
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Legg til partner',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _partnerCtrl,
                              decoration: const InputDecoration(
                                labelText: 'E-post eller brukernavn',
                                hintText: 'partner@eksempel.no eller partner123',
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _sending ? null : _sendPartner,
                                icon: const Icon(Icons.person_add_alt_1),
                                label: Text(_sending ? 'Sender…' : 'Legg til partner'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Incoming requests (persistent list + errors)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Forespørsler',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                              stream: _incoming,
                              builder: (context, snap) {
                                if (snap.hasError) {
                                  return Text('Requests error: ${snap.error}');
                                }
                                if (snap.connectionState == ConnectionState.waiting) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: LinearProgressIndicator(),
                                  );
                                }
                                final docs = snap.data?.docs ?? [];
                                if (docs.isEmpty) {
                                  return const Text('Ingen nye forespørsler');
                                }
                                return Column(
                                  children: docs.map((d) {
                                    final data = d.data();
                                    final fromUid = data['fromUid'] as String? ?? '';
                                    final reqId = d.id;
                                    return ListTile(
                                      leading: const Icon(Icons.person),
                                      title: Text('Forespørsel fra: $fromUid'),
                                      subtitle: Text('ID: $reqId'),
                                      trailing: Wrap(
                                        spacing: 8,
                                        children: [
                                          OutlinedButton(
                                            onPressed: () => _svc.declineRequest(requestId: reqId),
                                            child: const Text('Avslå'),
                                          ),
                                          ElevatedButton(
                                            onPressed: () => _svc.acceptRequest(
                                              requestId: reqId,
                                              fromUid: fromUid,
                                            ),
                                            child: const Text('Aksepter'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (_ensuring)
            const PositionedFillOverlay(),
        ],
      ),
    );
  }
}

class PositionedFillOverlay extends StatelessWidget {
  const PositionedFillOverlay({super.key});
  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: ColoredBox(
          color: Colors.transparent,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}
