-- Where an agent thread was started: 'app' (the operator's own chat) or 'a2a' (a connected
-- peer agent over the inbound A2A surface).
--
-- A peer resumes a conversation by contextId (`cmd-thread-<id>`), and thread ids are
-- sequential — so a peer could name ANY of the operator's app threads, read its whole
-- transcript into the run as history, and write into it. Inbound A2A now only continues
-- threads that A2A itself started. Every existing thread predates the column and is treated
-- as an app thread except those whose first message an inbound A2A exchange logged.
ALTER TABLE agent_threads ADD COLUMN origin TEXT NOT NULL DEFAULT 'app';

UPDATE agent_threads SET origin = 'a2a'
 WHERE id IN (
   SELECT CAST(substr(context_id, length('cmd-thread-') + 1) AS INTEGER)
     FROM peer_exchanges
    WHERE direction = 'in' AND context_id LIKE 'cmd-thread-%'
 )
   AND title = 'Connected agent conversation';
