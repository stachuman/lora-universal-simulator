// orchestrator/runtime/TimerWheel.cpp
#include "orchestrator/runtime/TimerWheel.h"

TimerHandle TimerWheel::scheduleAfter(uint64_t now_ms, uint64_t delay_ms, uint32_t period_ms) {
    TimerHandle h = _next_handle++;
    _heap.push(HeapEntry{now_ms + delay_ms, h, period_ms});
    return h;
}

void TimerWheel::cancel(TimerHandle h) {
    _cancelled.push_back(h);
}

bool TimerWheel::_isCancelled(TimerHandle h) const {
    // O(n), n bounded by MAX_PENDING_TIMERS_PER_NODE = 64 (Y1).
    for (TimerHandle c : _cancelled) {
        if (c == h) return true;
    }
    return false;
}

bool TimerWheel::peek(uint64_t /*now_ms*/, TimerEntry& out_entry) const {
    // Drop any cancelled entries that bubbled to the top so the caller sees
    // the next live deadline. We keep _heap and _cancelled mutable to do this
    // from a const method (peek is logically observation-only).
    while (!_heap.empty() && _isCancelled(_heap.top().handle)) {
        _heap.pop();
    }
    if (_heap.empty()) return false;
    const HeapEntry& top = _heap.top();
    out_entry.deadline_ms = top.deadline_ms;
    out_entry.handle      = top.handle;
    out_entry.period_ms   = top.period_ms;
    return true;
}

bool TimerWheel::popDue(uint64_t now_ms, TimerEntry& out_entry) {
    while (!_heap.empty() && _isCancelled(_heap.top().handle)) {
        _heap.pop();
    }
    if (_heap.empty()) return false;
    const HeapEntry& top = _heap.top();
    if (top.deadline_ms > now_ms) return false;

    out_entry.deadline_ms = top.deadline_ms;
    out_entry.handle      = top.handle;
    out_entry.period_ms   = top.period_ms;
    _heap.pop();

    if (out_entry.period_ms > 0) {
        // Recurring: re-push with same handle so cancel() still works.
        _heap.push(HeapEntry{
            out_entry.deadline_ms + out_entry.period_ms,
            out_entry.handle,
            out_entry.period_ms
        });
    }
    return true;
}

size_t TimerWheel::size() const {
    // Includes cancelled-but-not-popped entries; document at the API level.
    return _heap.size();
}
