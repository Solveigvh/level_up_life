import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  static const int levelBase = 100; // XP per level step
  late final TabController _tab;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _xpAwardSub;

  // UI state: show instant strike-through after completion
  final Set<String> _justCompleted = {};

  User? get _user => _auth.currentUser;

  // ---- Level helpers ----
  int _xpForNextLevel(int level) => level * levelBase;
  double _progressToNextLevel({required int xp, required int level}) {
    final need = _xpForNextLevel(level);
    return (xp / (need == 0 ? 1 : need)).clamp(0.0, 1.0);
  }

  DateTime _now() => DateTime.now();

  DateTime _computeNextDue(String frequency, {int? customDays}) {
    final now = _now();
    switch (frequency) {
      case 'daily':
        return now.add(const Duration(days: 1));
      case 'weekly':
        return now.add(const Duration(days: 7));
      case 'biweekly':
        return now.add(const Duration(days: 14));
      case 'monthly':
        return DateTime(now.year, now.month + 1, now.day, now.hour, now.minute);
      case 'quarterly':
        return DateTime(now.year, now.month + 3, now.day, now.hour, now.minute);
      case 'custom':
        return now.add(Duration(days: customDays ?? 3));
      case 'once':
      default:
        return now;
    }
  }

  bool _isDueThisWeek(dynamic nextDueAtRaw) {
    if (nextDueAtRaw == null) return true;
    final due = nextDueAtRaw is Timestamp
        ? nextDueAtRaw.toDate()
        : (nextDueAtRaw as DateTime);
    final in7 = _now().add(const Duration(days: 7));
    // strictly before 7 days (so +7d after completion disappears)
    return due.isBefore(in7);
  }

  // ---- lifecycle ----
  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this)..addListener(() => setState(() {}));
    _startXpAwardListener();
  }

  @override
  void dispose() {
    _xpAwardSub?.cancel();
    _tab.dispose();
    super.dispose();
  }

  // ---- XP awarding on completed reviews ----
  Future<void> _awardXpToMe(int amount) async {
    final u = _user;
    if (u == null) return;
    final ref = _db.collection('users').doc(u.uid);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final data = snap.data() ?? {};
      int xp = (data['xp'] ?? 0) as int;
      int level = (data['level'] ?? 1) as int;
      xp += amount;
      while (xp >= _xpForNextLevel(level)) {
        xp -= _xpForNextLevel(level);
        level += 1;
      }
      tx.update(ref, {
        'xp': xp,
        'level': level,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  void _startXpAwardListener() {
    final u = _user;
    if (u == null) return;
    _xpAwardSub = _db
        .collection('chore_reviews')
        .where('requesterUid', isEqualTo: u.uid)
        .where('status', isEqualTo: 'completed')
        .where('processedByRequester', isNull: true)
        .snapshots()
        .listen((qs) async {
      for (final d in qs.docs) {
        final data = d.data();
        final awarded = (data['awardedXp'] ?? 0) as int;
        try {
          await _awardXpToMe(awarded);
          await d.reference.update({
            'processedByRequester': true,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
      }
    });
  }

  // ---- complete chore flow ----
  Future<void> _confirmAndComplete(
      DocumentReference<Map<String, dynamic>> ref, String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Marker som ferdig?'),
        content: Text('Vil du markere «$name» som ferdig?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nei')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ja')),
        ],
      ),
    );
    if (ok == true) {
      await _completeChore(ref);
      if (!mounted) return;
      setState(() => _justCompleted.add(id));
    }
  }

  Future<void> _completeChore(
      DocumentReference<Map<String, dynamic>> choreRef) async {
    final u = _user;
    if (u == null) return;

    final choreSnap = await choreRef.get();
    if (!choreSnap.exists) return;
    final chore = choreSnap.data()!;
    final int xp = (chore['xp'] ?? 0) as int;
    final String freq = (chore['frequency'] ?? 'once') as String;
    final int? customDays = (chore['customDays'] as int?);
    final String choreName = (chore['name'] ?? '') as String;

    final meDoc = await _db.collection('users').doc(u.uid).get();
    final me = meDoc.data() ?? {};
    final partnerLinked = (me['partnerLinked'] ?? false) == true;
    final partnerUid = me['partnerUid'] as String?;

    final updates = <String, dynamic>{
      'lastCompletedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (freq == 'once') {
      // one-off: hide from lists
      updates['active'] = false;
      updates['nextDueAt'] = null;
    } else {
      updates['nextDueAt'] =
          Timestamp.fromDate(_computeNextDue(freq, customDays: customDays));
    }
    await choreRef.update(updates);

    if (partnerLinked && partnerUid != null && partnerUid.isNotEmpty) {
      final reviewRef = _db.collection('chore_reviews').doc();
      await reviewRef.set({
        'ownerUid': partnerUid,          // who must rate
        'requesterUid': u.uid,           // who did the chore
        'choreId': choreRef.id,
        'choreName': choreName,
        'xp': xp,
        'status': 'pending',
        'rating': null,
        'comment': null,
        'awardedXp': null,
        'processedByRequester': null,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Venter på partnerens vurdering ⭐')));
    } else {
      await _awardXpToMe(xp);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ferdig! +$xp XP')));
    }
  }

  // ---- add chore ----
  Future<void> _openAddChoreSheet() async {
    final nameCtrl = TextEditingController();
    final xpCtrl = TextEditingController(text: '20');
    final estCtrl = TextEditingController(text: '20');
    String freq = 'weekly';
    int customDays = 3;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final bottom = MediaQuery.of(sheetCtx).viewInsets.bottom;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(left: 16, right: 16, bottom: bottom + 16, top: 16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Legg til oppgave', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Navn på oppgave')),
                    TextField(controller: xpCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'XP (heltall)')),
                    TextField(controller: estCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Estimerte minutter')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: freq,
                      items: const [
                        DropdownMenuItem(value: 'once', child: Text('Én gang')),
                        DropdownMenuItem(value: 'daily', child: Text('Daglig')),
                        DropdownMenuItem(value: 'weekly', child: Text('Ukentlig')),
                        DropdownMenuItem(value: 'biweekly', child: Text('Hver 14. dag')),
                        DropdownMenuItem(value: 'monthly', child: Text('Månedlig')),
                        DropdownMenuItem(value: 'quarterly', child: Text('Kvartalsvis')),
                        DropdownMenuItem(value: 'custom', child: Text('Egendefinert (x dager)')),
                      ],
                      onChanged: (v) => setSheetState(() => freq = v ?? 'weekly'),
                      decoration: const InputDecoration(labelText: 'Hyppighet'),
                    ),
                    if (freq == 'custom')
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Antall dager'),
                          onChanged: (v) {
                            final parsed = int.tryParse(v);
                            if (parsed != null) setSheetState(() => customDays = parsed);
                          },
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Lagre'),
                        onPressed: () async {
                          final u = _user;
                          if (u == null) return;

                          final name = nameCtrl.text.trim();
                          final xp = int.tryParse(xpCtrl.text.trim()) ?? 0;
                          final est = int.tryParse(estCtrl.text.trim()) ?? 0;
                          if (name.isEmpty || xp <= 0) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Skriv inn navn og positiv XP.')),
                            );
                            return;
                          }

                          try {
                            final ref = _db.collection('users').doc(u.uid).collection('chores').doc();
                            await ref.set({
                              'name': name,
                              'xp': xp,
                              'frequency': freq,
                              'customDays': freq == 'custom' ? customDays : null,
                              'estimatedMinutes': est,
                              'lastCompletedAt': null,
                              'nextDueAt': Timestamp.fromDate(
                                _computeNextDue(freq, customDays: customDays),
                              ),
                              'active': true,
                              'createdAt': FieldValue.serverTimestamp(),
                              'updatedAt': FieldValue.serverTimestamp(),
                            });

                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(content: Text('Oppgave lagt til')));
                          } on FirebaseException catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text('Kunne ikke lagre: ${e.message}')));
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text('Kunne ikke lagre: $e')));
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---- streams ----
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream() {
    final u = _user;
    if (u == null) return null;
    return _db.collection('users').doc(u.uid).snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _myChoresStream() {
    final u = _user;
    if (u == null) return null;
    return _db.collection('users').doc(u.uid).collection('chores').snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _partnerChoresStream(String partnerUid) {
    return _db.collection('users').doc(partnerUid).collection('chores').snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>>? _myPendingReviewsStream() {
    final u = _user;
    if (u == null) return null;
    return _db
        .collection('chore_reviews')
        .where('ownerUid', isEqualTo: u.uid)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    final u = _user;
    if (u == null) return const Scaffold(body: Center(child: Text('Not logged in')));

    final userS = _userStream();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Level Up Life'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.task_alt), text: 'Mine'),
            Tab(icon: Icon(Icons.group), text: 'Partner'),
            Tab(icon: Icon(Icons.star_rate), text: 'Vurderinger'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
            tooltip: 'Logg ut',
          ),
        ],
      ),

      floatingActionButton: (_tab.index == 0)
          ? StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _myChoresStream(),
              builder: (context, snap) {
                final chores = snap.data?.docs ?? const [];
                return FloatingActionButton.extended(
                  onPressed: chores.isEmpty ? null : () => _openPlayPicker(chores),
                  icon: const Icon(Icons.casino),
                  label: const Text('Spill'),
                );
              },
            )
          : null,

      body: TabBarView(
        controller: _tab,
        children: [
          // TAB 1: Mine
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: userS,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final data = snap.data?.data() ?? {};
                  final level = (data['level'] ?? 1) as int;
                  final xp = (data['xp'] ?? 0) as int;
                  final next = _xpForNextLevel(level);
                  final progress = _progressToNextLevel(xp: xp, level: level);

                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Din progresjon', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Row(children: [
                            Chip(label: Text('Level: $level')),
                            const SizedBox(width: 8),
                            Chip(label: Text('XP: $xp / $next')),
                          ]),
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: progress),
                          const SizedBox(height: 8),
                          Text('Neste level ved $next XP'),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              _MyChoresCard(
                choresStream: _myChoresStream(),
                isMine: true,
                completedNow: _justCompleted,
                onConfirmComplete: _confirmAndComplete,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Legg til oppgave'),
                  onPressed: _openAddChoreSheet,
                ),
              ),
            ],
          ),

          // TAB 2: Partner (read-only)
          Padding(
            padding: const EdgeInsets.all(16),
            child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: userS,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final me = snap.data?.data() ?? {};
                final partnerUid = me['partnerUid'] as String?;
                final linked = (me['partnerLinked'] ?? false) == true &&
                    partnerUid != null &&
                    partnerUid.isNotEmpty;
                if (!linked) return const Center(child: Text('Ingen partner koblet.'));
                return _MyChoresCard(
                  choresStream: _partnerChoresStream(partnerUid),
                  isMine: false,
                  completedNow: const <String>{},
                  onConfirmComplete: (_, __, ___) async {},
                );
              },
            ),
          ),

          // TAB 3: Reviews
          Padding(
            padding: const EdgeInsets.all(16),
            child: _ReviewsCard(
              pendingStream: _myPendingReviewsStream(),
              onRate: _openRateSheet,
            ),
          ),
        ],
      ),
    );
  }

  // Quick-Play
  Future<void> _openPlayPicker(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> chores) async {
    final minutesCtrl = TextEditingController(text: '20');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hvor mange minutter har du?'),
        content: TextField(
          controller: minutesCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Minutter'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Avbryt')),
          ElevatedButton(
            onPressed: () {
              final m = int.tryParse(minutesCtrl.text.trim()) ?? 0;
              Navigator.pop(ctx);
              if (m > 0) _spinAndPick(chores, m);
            },
            child: const Text('Spill!'),
          ),
        ],
      ),
    );
  }

  void _spinAndPick(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> chores, int minutes) {
    final due = chores.where((d) {
      final data = d.data();
      final est = (data['estimatedMinutes'] ?? 0) as int;
      final active = (data['active'] ?? true) == true;
      return active && est <= minutes && _isDueThisWeek(data['nextDueAt']);
    }).toList();

    if (due.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingen oppgaver passer den tidsmengden 🤷')),
      );
      return;
    }

    final picked = due[Random().nextInt(due.length)];
    final name = picked.data()['name'] ?? 'Oppgave';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🎯 Gjør denne!'),
        content: Text('Jeg valgte: $name'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Lukk')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _confirmAndComplete(picked.reference, picked.id, name);
            },
            child: const Text('Start / Ferdig'),
          ),
        ],
      ),
    );
  }

  // Reviews UI
  Future<void> _openRateSheet(
      DocumentSnapshot<Map<String, dynamic>> reviewDoc) async {
    final data = reviewDoc.data()!;
    int rating = 5;
    final commentCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return StatefulBuilder(builder: (ctx, setSheet) {
          return Padding(
            padding: EdgeInsets.only(left: 16, right: 16, bottom: bottom + 16, top: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vurder «${data['choreName'] ?? 'Oppgave'}»',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(
                  children: List.generate(5, (i) {
                    final filled = i < rating;
                    return IconButton(
                      icon: Icon(filled ? Icons.star : Icons.star_border),
                      onPressed: () => setSheet(() => rating = i + 1),
                    );
                  }),
                ),
                TextField(
                  controller: commentCtrl,
                  decoration: const InputDecoration(labelText: 'Kommentar (valgfritt)'),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.send),
                    label: const Text('Send vurdering'),
                    onPressed: () async {
                      try {
                        final baseXp = (data['xp'] ?? 0) as int;
                        final awarded = ((baseXp * rating) / 5).round();
                        await reviewDoc.reference.update({
                          'rating': rating,
                          'comment': commentCtrl.text.trim().isEmpty
                              ? null
                              : commentCtrl.text.trim(),
                          'awardedXp': awarded,
                          'status': 'completed',
                          'reviewedByUid': _user!.uid,
                          'reviewedAt': FieldValue.serverTimestamp(),
                          'updatedAt': FieldValue.serverTimestamp(),
                        });
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Vurdering sendt (+$awarded XP til utfører)')),
                        );
                      } on FirebaseException catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('Kunne ikke sende: ${e.message}')));
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('Kunne ikke sende: $e')));
                      }
                    },
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }
}

// ======= shared cards =======

class _MyChoresCard extends StatelessWidget {
  const _MyChoresCard({
    required this.choresStream,
    required this.isMine,
    required this.completedNow,
    required this.onConfirmComplete,
  });

  final Stream<QuerySnapshot<Map<String, dynamic>>>? choresStream;
  final bool isMine;
  final Set<String> completedNow;
  final Future<void> Function(
    DocumentReference<Map<String, dynamic>> ref,
    String id,
    String name,
  ) onConfirmComplete;

  bool _isDueThisWeek(dynamic nextDueAtRaw) {
    if (nextDueAtRaw == null) return true;
    final due = nextDueAtRaw is Timestamp
        ? nextDueAtRaw.toDate()
        : (nextDueAtRaw as DateTime);
    final in7 = DateTime.now().add(const Duration(days: 7));
    return due.isBefore(in7);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: choresStream,
          builder: (context, snap) {
            if (snap.hasError) return Text('Feil: ${snap.error}');
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              );
            }
            final all = snap.data?.docs ?? [];
            // active only, due this week
            final due = all.where((d) {
              final c = d.data();
              final active = (c['active'] ?? true) == true;
              return active && _isDueThisWeek(c['nextDueAt']);
            }).toList();

            final title = isMine ? 'Oppgaver denne uken' : 'Partner sine oppgaver';

            if (all.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(isMine ? 'Ingen oppgaver enda. Legg til en!' : 'Ingen oppgaver å vise.'),
                ],
              );
            }
            if (due.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('Ingen oppgaver forfall denne uken.'),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ...due.map((doc) {
                  final c = doc.data();
                  final id = doc.id;
                  final name = (c['name'] ?? '') as String;
                  final xp = (c['xp'] ?? 0) as int;
                  final est = (c['estimatedMinutes'] ?? 0) as int;
                  final freq = (c['frequency'] ?? 'once') as String;

                  final justDone = completedNow.contains(id);
                  final titleStyle = justDone
                      ? const TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Colors.grey)
                      : null;

                  return ListTile(
                    leading: isMine
                        ? Checkbox(
                            value: justDone,
                            onChanged: (_) => onConfirmComplete(doc.reference, id, name),
                          )
                        : const Icon(Icons.check_box_outline_blank),
                    title: Text(name, style: titleStyle),
                    subtitle: Text('$xp XP • $est min • $freq',
                        style: titleStyle),
                    trailing: isMine
                        ? (justDone
                            ? const Icon(Icons.check, color: Colors.green)
                            : const SizedBox.shrink())
                        : const Text('Lesemodus'),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ReviewsCard extends StatelessWidget {
  const _ReviewsCard({
    required this.pendingStream,
    required this.onRate,
  });

  final Stream<QuerySnapshot<Map<String, dynamic>>>? pendingStream;
  final Future<void> Function(DocumentSnapshot<Map<String, dynamic>> doc) onRate;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: pendingStream,
          builder: (context, snap) {
            if (snap.hasError) return Text('Feil: ${snap.error}');
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              );
            }
            final docs = snap.data?.docs ?? [];
            if (docs.isEmpty) return const Text('Ingen forespørsler til vurdering.');

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: docs.map((d) {
                final x = d.data();
                final chore = (x['choreName'] ?? '') as String;
                final xp = (x['xp'] ?? 0) as int;
                final requester = (x['requesterUid'] ?? '') as String;
                return ListTile(
                  leading: const Icon(Icons.rate_review),
                  title: Text(chore),
                  subtitle: Text('Fra: $requester • $xp XP'),
                  trailing: ElevatedButton(
                    onPressed: () => onRate(d),
                    child: const Text('Vurder'),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}
