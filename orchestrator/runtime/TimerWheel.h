// orchestrator/runtime/TimerWheel.h
//
// Per-node priority queue of pending timer entries. Entries are scheduled by
// absolute deadline (in milliseconds); the simulator main loop peeks the
// earliest deadline and dispatches whichever entries are due.
//
// Cancellation uses a tombstone strategy: cancel() appends the handle to a
// small "_cancelled" vector, and peek/popDue lazily skip cancelled entries
// when they reach the top of the heap. This keeps cancel() O(1) at the cost
// of a linear scan in _isCancelled(); for Y1 with bounded timer churn (see
// MAX_PENDING_TIMERS_PER_NODE = 64) this is fine.

#pragma once
#include <cstddef>
#include <cstdint>
#include <queue>
#include <vector>

using TimerHandle = uint64_t;
constexpr TimerHandle kInvalidTimer = 0;

struct TimerEntry {
    uint64_t deadline_ms;
    TimerHandle handle;
    uint32_t period_ms;        // 0 = one-shot, >0 = recurring
};

class TimerWheel {
public:
    // Schedule an entry to fire at (now_ms + delay_ms). If period_ms > 0, the
    // entry recurs: when popped, popDue() re-pushes it with deadline += period.
    // Returns the assigned handle (unique per TimerWheel instance, never 0).
    TimerHandle scheduleAfter(uint64_t now_ms, uint64_t delay_ms, uint32_t period_ms = 0);

    // Mark a handle as cancelled. The entry is left in the heap and dropped
    // lazily when peek/popDue encounters it at the top.
    void cancel(TimerHandle h);

    // Non-destructive: copies the earliest non-cancelled entry into out_entry
    // and returns true. Returns false if the heap is empty (after skipping
    // cancelled entries at the top). Note: the now_ms argument is currently
    // unused but kept in the API for future use (e.g. expiry-window logic).
    bool peek(uint64_t now_ms, TimerEntry& out_entry) const;

    // If the earliest non-cancelled entry has deadline_ms <= now_ms, pop it,
    // copy to out_entry, and return true. If recurring (period_ms > 0), the
    // entry is re-pushed with deadline_ms += period_ms (handle preserved, so
    // cancel() continues to work).
    bool popDue(uint64_t now_ms, TimerEntry& out_entry);

    // Total entries in the underlying heap, INCLUDING cancelled-but-not-yet-
    // popped entries. Useful for debug/asserts; not a precise live count.
    size_t size() const;

private:
    struct HeapEntry {
        uint64_t deadline_ms;
        TimerHandle handle;
        uint32_t period_ms;
    };
    struct Cmp {
        bool operator()(const HeapEntry& a, const HeapEntry& b) const {
            return a.deadline_ms > b.deadline_ms;
        }
    };

    // mutable so the const peek() can drop cancelled entries from the top.
    mutable std::priority_queue<HeapEntry, std::vector<HeapEntry>, Cmp> _heap;
    mutable std::vector<TimerHandle> _cancelled;   // small; sweep on cancel
    TimerHandle _next_handle = 1;

    bool _isCancelled(TimerHandle h) const;
};
