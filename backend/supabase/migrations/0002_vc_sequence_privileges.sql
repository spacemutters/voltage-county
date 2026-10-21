-- Phase 14 security review: the designer's two identity sequences (the id columns of vc_designer_usage and
-- vc_designs) still carried the project's default USAGE grant to anon and authenticated. The tables themselves
-- give those roles nothing (0001_designer.sql), so the grant can't read or write any row, but only the backend
-- (service role) ever needs the sequences. Least privilege: take it away. Safe to run more than once.

revoke all on sequence public.vc_designer_usage_id_seq, public.vc_designs_id_seq from public, anon, authenticated;
grant usage, select on sequence public.vc_designer_usage_id_seq, public.vc_designs_id_seq to service_role;
