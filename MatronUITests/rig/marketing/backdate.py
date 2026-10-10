#!/usr/bin/env python3
"""Back-date the seeded journal so every time on screen reads before the
simulator's 9:41 status bar. Each conversation's events end at a fixed clock
time (today, or N days back) and are spread over the few minutes before it;
items, comments, milestones and missions follow their conversation.
Usage: backdate.py /path/to/matron.db HH:MM
HH:MM is the clock the status bar will show (today); every time on screen is
placed before it. With "now" the current time is the clock, so relative
labels ("7h ago") stay small too — rig.sh then overrides the status bar to
match."""
import sqlite3, sys, time
from datetime import datetime, timedelta

db = sqlite3.connect(sys.argv[1])
clock = sys.argv[2] if len(sys.argv) > 2 else '9:41'
now = datetime.now()
if clock == 'now':
    base = now.replace(second=0, microsecond=0)
else:
    hh, mm = (int(x) for x in clock.split(':'))
    base = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
MIN = 60_000

def at(days_ago, minutes_before):
    """A moment `minutes_before` the clock, `days_ago` days back."""
    return int((base - timedelta(days=days_ago, minutes=minutes_before)).timestamp() * 1000)

# convo -> (end time, span minutes)
plan = {
    'mk-auth-sub':  (at(0, 1), 3),
    'mk-auth':      (at(0, 2), 6),
    'mk-coord':     (at(0, 3), 4),
    'mk-release':   (at(0, 5), 30),
    'mk-flaky':     (at(0, 29), 8),
    'mk-checkout':  (at(0, 50), 20),
    'mk-docs':      (at(1, -400), 40),   # yesterday afternoon
    'mk-nightly':   (at(1, 220), 2),    # yesterday, early morning
}
cols = {t: [r[1] for r in db.execute(f'PRAGMA table_info({t})')] for (t,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}

def shift_convo(convo, end, span):
    rows = db.execute("SELECT seq FROM events WHERE convo_id=? ORDER BY seq", (convo,)).fetchall()
    n = len(rows)
    for i, (seq,) in enumerate(rows):
        ts = end - (n - 1 - i) * int(span * MIN / max(1, n - 1)) if n > 1 else end
        db.execute("UPDATE events SET ts=? WHERE convo_id=? AND seq=?", (ts, convo, seq))
    for col in ('created_at', 'updated_at', 'last_event_ts', 'last_activity_at'):
        if col in cols.get('conversations', []):
            db.execute(f"UPDATE conversations SET {col}=? WHERE id=?", (end - (span * MIN if col == 'created_at' else 0), convo))
    return end, span

for convo, (end, span) in plan.items():
    shift_convo(convo, end, span)

# Items and missions hang off their origin conversation; milestones and
# comments are staggered so threads read in order. Memories are days old.
def end_of(convo): return plan[convo][0] if convo in plan else None
for iid, convo in db.execute("SELECT id, origin_convo_id FROM items").fetchall():
    end = end_of(convo)
    if end is None: continue
    db.execute("UPDATE items SET created_at=?, updated_at=? WHERE id=?", (end - 2 * MIN, end - MIN, iid))
    for k, (cid,) in enumerate(db.execute("SELECT id FROM item_comments WHERE item_id=? ORDER BY id", (iid,)).fetchall()):
        db.execute("UPDATE item_comments SET created_at=? WHERE id=?", (end - 2 * MIN + (k + 1) * 20_000, cid))
for mid, convo in db.execute("SELECT id, origin_convo_id FROM missions").fetchall():
    end = end_of(convo)
    if end is None: continue
    span = plan[convo][1]
    db.execute("UPDATE missions SET created_at=?, updated_at=?, last_milestone_at=?, status_updated_at=? WHERE id=?",
               (end - span * MIN, end - MIN, end - MIN, end - MIN, mid))
    ms = db.execute("SELECT id FROM milestones WHERE mission_id=? ORDER BY id", (mid,)).fetchall()
    for k, (mlid,) in enumerate(ms):
        db.execute("UPDATE milestones SET created_at=? WHERE id=?", (end - span * MIN + (k + 1) * int(span * MIN / (len(ms) + 1)), mlid))
for (pid,) in db.execute("SELECT id FROM projects").fetchall():
    ms = db.execute("SELECT MIN(created_at), MAX(updated_at) FROM missions WHERE project_id=?", (pid,)).fetchone()
    if ms[0] is None: continue
    db.execute("UPDATE projects SET created_at=?, updated_at=?, status_updated_at=? WHERE id=?", (ms[0], ms[1], ms[1], pid))
for k, (name,) in enumerate(db.execute("SELECT name FROM memories ORDER BY name").fetchall()):
    db.execute("UPDATE memories SET created_at=?, updated_at=? WHERE name=?", (at(9 + k, 0), at(2 + k, 0), name))
db.execute("UPDATE search_messages SET ts=(SELECT ts FROM events e WHERE e.convo_id=search_messages.convo_id AND e.seq=search_messages.seq)")
# The journal seeds the Coordinator's routines on assignment and fires them
# on schedule; a fired routine lands as an event the apps don't render.
db.execute("UPDATE routines SET enabled=0")
db.execute("DELETE FROM events WHERE type='routine'")
db.commit()
print('back-dated', len(plan), 'conversations')
