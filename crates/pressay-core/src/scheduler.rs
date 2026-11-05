use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Session {
    Idle,
    Dictation,
    Meeting,
}
/// Preserve the shipping policy: one resident worker; dictation is blocked
/// during meetings. A bounded FIFO prevents a slow model from growing RAM forever.
pub struct Scheduler<T> {
    session: Session,
    generation: u64,
    capacity: usize,
    pending: VecDeque<T>,
}
impl<T> Scheduler<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            session: Session::Idle,
            generation: 0,
            capacity,
            pending: VecDeque::new(),
        }
    }
    pub fn start(&mut self, session: Session) -> Result<u64> {
        if session == Session::Idle || self.session != Session::Idle {
            return Err(Error::Message(
                "Finish the current dictation or meeting first".into(),
            ));
        }
        self.generation += 1;
        self.session = session;
        Ok(self.generation)
    }
    pub fn push(&mut self, generation: u64, item: T) -> Result<()> {
        if !self.accepts(generation) {
            return Err(Error::Cancelled);
        }
        if self.pending.len() >= self.capacity {
            return Err(Error::Message(
                "Speech processing is falling behind. Stop recording and let it finish.".into(),
            ));
        }
        self.pending.push_back(item);
        Ok(())
    }
    pub fn pop(&mut self) -> Option<T> {
        self.pending.pop_front()
    }
    pub fn accepts(&self, generation: u64) -> bool {
        self.session != Session::Idle && self.generation == generation
    }
    pub fn finish(&mut self, generation: u64) -> Result<()> {
        if !self.accepts(generation) {
            return Err(Error::Cancelled);
        }
        if !self.pending.is_empty() {
            return Err(Error::Message("Speech jobs are still pending".into()));
        }
        self.session = Session::Idle;
        Ok(())
    }
    pub fn cancel(&mut self) {
        self.generation += 1;
        self.session = Session::Idle;
        self.pending.clear();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn blocks_parallel_sessions_and_stale_completions() {
        let mut q = Scheduler::new(1);
        let g = q.start(Session::Meeting).unwrap();
        assert!(q.start(Session::Dictation).is_err());
        q.push(g, 1).unwrap();
        assert!(q.push(g, 2).is_err());
        assert!(q.finish(g).is_err());
        q.cancel();
        let next = q.start(Session::Dictation).unwrap();
        assert!(!q.accepts(g));
        assert!(q.push(g, 3).is_err());
        q.finish(next).unwrap();
    }
}
