-- Checklist items whose parent is gone.
--
-- `task_items.parent_id` is polymorphic (assignment | goal | activity), so no foreign key can
-- cascade it, and until now deleting an assignment, goal or activity left its checklist behind.
-- The delete paths now clean up (core/task_items.delete_for_parent); this clears what the old
-- code already stranded. Account deletion was never affected (task_items is swept there).
DELETE FROM task_items
 WHERE (parent_type = 'assignment' AND parent_id NOT IN (SELECT id FROM assignments))
    OR (parent_type = 'goal'       AND parent_id NOT IN (SELECT id FROM goals))
    OR (parent_type = 'activity'   AND parent_id NOT IN (SELECT id FROM activities));
