-- Additive fresh-install snapshot. Refuses existing application schemas; never deletes user data.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname IN ('openbot','jevie_runtime','drizzle')) THEN
  RAISE EXCEPTION 'OpenBot schemas already exist; refusing fresh installation';
 END IF;
END $$;
--
-- PostgreSQL database dump
--


-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: drizzle; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA drizzle;


--
-- Name: jevie_runtime; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA jevie_runtime;


--
-- Name: openbot; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA openbot;


--
-- Name: agent_type; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.agent_type AS ENUM (
    'built_in',
    'remote_ag_ui',
    'remote_mastra'
);


--
-- Name: agent_visibility; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.agent_visibility AS ENUM (
    'public',
    'private'
);


--
-- Name: credential_kind; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.credential_kind AS ENUM (
    'model',
    'connector',
    'agent',
    'mcp',
    'mcp_oauth_client',
    'mcp_user_token'
);


--
-- Name: responsibility_run_status; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.responsibility_run_status AS ENUM (
    'queued',
    'running',
    'waiting',
    'succeeded',
    'failed',
    'skipped'
);


--
-- Name: responsibility_status; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.responsibility_status AS ENUM (
    'active',
    'paused',
    'completed'
);


--
-- Name: role; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.role AS ENUM (
    'admin',
    'user'
);


--
-- Name: routine_run_status; Type: TYPE; Schema: openbot; Owner: -
--

CREATE TYPE openbot.routine_run_status AS ENUM (
    'succeeded',
    'failed',
    'skipped',
    'waiting'
);


--
-- Name: prevent_audit_event_mutation(); Type: FUNCTION; Schema: openbot; Owner: -
--

CREATE FUNCTION openbot.prevent_audit_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'openbot'
    AS $$
DECLARE
  retention_days integer;
BEGIN
  -- Answered before anything else is read, so no setting and no missing OLD record can change it.
  IF TG_OP = 'TRUNCATE' OR TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'Audit events are append-only';
  END IF;

  -- `true` so a session that never set it reads NULL instead of raising, which is the ordinary case
  -- and has to stay a plain refusal.
  BEGIN
    retention_days := nullif(current_setting('openbot.audit_retention_days', true), '')::integer;
  EXCEPTION WHEN others THEN
    retention_days := NULL;
  END;

  IF retention_days IS NULL OR retention_days < 1 THEN
    RAISE EXCEPTION 'Audit events are append-only';
  END IF;

  IF OLD.created_at >= now() - (retention_days || ' days')::interval THEN
    RAISE EXCEPTION 'Audit events are append-only within the retention window';
  END IF;

  RETURN OLD;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: __drizzle_migrations; Type: TABLE; Schema: drizzle; Owner: -
--

CREATE TABLE drizzle.__drizzle_migrations (
    id integer NOT NULL,
    hash text NOT NULL,
    created_at bigint
);


--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE; Schema: drizzle; Owner: -
--

CREATE SEQUENCE drizzle.__drizzle_migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: drizzle; Owner: -
--

ALTER SEQUENCE drizzle.__drizzle_migrations_id_seq OWNED BY drizzle.__drizzle_migrations.id;


--
-- Name: threads; Type: TABLE; Schema: jevie_runtime; Owner: -
--

CREATE TABLE jevie_runtime.threads (
    id text NOT NULL,
    owner_id text NOT NULL,
    agent_id text NOT NULL,
    name text,
    messages jsonb DEFAULT '[]'::jsonb NOT NULL,
    events jsonb DEFAULT '[]'::jsonb NOT NULL,
    active_run text,
    lock_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT threads_events_check CHECK ((jsonb_typeof(events) = 'array'::text)),
    CONSTRAINT threads_id_check CHECK (((length(id) >= 1) AND (length(id) <= 200))),
    CONSTRAINT threads_messages_check CHECK ((jsonb_typeof(messages) = 'array'::text))
);


--
-- Name: accounts; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.accounts (
    id text NOT NULL,
    account_id text NOT NULL,
    provider_id text NOT NULL,
    user_id text NOT NULL,
    access_token text,
    refresh_token text,
    id_token text,
    access_token_expires_at timestamp with time zone,
    refresh_token_expires_at timestamp with time zone,
    scope text,
    password text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    issuer text
);


--
-- Name: action_policy; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.action_policy (
    id text NOT NULL,
    mode text NOT NULL,
    deny text[] NOT NULL,
    allow text[] NOT NULL,
    updated_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: action_records; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.action_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    surface text NOT NULL,
    bot_id text,
    actor_user_id text,
    tool_name text NOT NULL,
    command text NOT NULL,
    outcome text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT action_records_surface_check CHECK ((surface = ANY (ARRAY['cloud'::text, 'local'::text])))
);


--
-- Name: agent_preferences; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.agent_preferences (
    user_id text NOT NULL,
    agent_id text NOT NULL,
    hidden_at timestamp with time zone,
    pinned_at timestamp with time zone
);


--
-- Name: agent_profiles; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.agent_profiles (
    agent_id text NOT NULL,
    owner_user_id text,
    title text NOT NULL,
    role_description text NOT NULL,
    avatar_seed text NOT NULL,
    visibility openbot.agent_visibility NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    callback_token_hash text,
    callback_token_issued_at timestamp with time zone
);


--
-- Name: agents; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.agents (
    id text NOT NULL,
    name text NOT NULL,
    type openbot.agent_type NOT NULL,
    configuration jsonb NOT NULL,
    package_id uuid,
    override jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_access_requests; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.app_access_requests (
    id text NOT NULL,
    requested_by text NOT NULL,
    agent_id text,
    app_key text NOT NULL,
    app_title text NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    resolved_by text,
    CONSTRAINT app_access_requests_kind_check CHECK ((kind = ANY (ARRAY['enable'::text, 'grant'::text, 'connect_shared'::text]))),
    CONSTRAINT app_access_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'dismissed'::text, 'cancelled'::text])))
);


--
-- Name: approval_preferences; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.approval_preferences (
    owner_user_id text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    auto_review boolean DEFAULT false NOT NULL,
    host_commands text DEFAULT 'ask'::text NOT NULL,
    CONSTRAINT approval_preferences_host_commands_check CHECK ((host_commands = ANY (ARRAY['ask'::text, 'allow'::text, 'never'::text])))
);


--
-- Name: approval_requests; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.approval_requests (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    run_id text NOT NULL,
    tool_call_id text NOT NULL,
    action_digest text NOT NULL,
    action jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    decision text,
    result jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    consumed_at timestamp with time zone,
    completed_at timestamp with time zone,
    CONSTRAINT approval_decision_check CHECK ((decision = ANY (ARRAY['allow_once'::text, 'allow_always'::text, 'deny'::text, 'handled'::text]))),
    CONSTRAINT approval_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'consumed'::text, 'completed'::text])))
);


--
-- Name: approval_rules; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.approval_rules (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    bot_id text NOT NULL,
    tool_ref text NOT NULL,
    effect text NOT NULL,
    scope text NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    behaviour text DEFAULT 'allow'::text NOT NULL,
    CONSTRAINT approval_rules_behaviour_check CHECK ((behaviour = ANY (ARRAY['allow'::text, 'pre_approved'::text, 'ask'::text, 'hand_off'::text])))
);


--
-- Name: approval_team_rules; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.approval_team_rules (
    id text NOT NULL,
    bot_id text NOT NULL,
    tool_ref text NOT NULL,
    effect text NOT NULL,
    scope text NOT NULL,
    behaviour text NOT NULL,
    created_by text,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_team_rules_behaviour_check CHECK ((behaviour = ANY (ARRAY['allow'::text, 'pre_approved'::text, 'ask'::text, 'hand_off'::text])))
);


--
-- Name: approval_team_settings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.approval_team_settings (
    id text NOT NULL,
    enforce_auto_review boolean DEFAULT false NOT NULL,
    custom_rules_enabled boolean DEFAULT true NOT NULL,
    host_commands_cap text DEFAULT 'allow'::text NOT NULL,
    updated_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT approval_team_settings_host_commands_cap_check CHECK ((host_commands_cap = ANY (ARRAY['ask'::text, 'allow'::text, 'never'::text])))
);


--
-- Name: attachments; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    channel_id text NOT NULL,
    uploaded_by text NOT NULL,
    name text NOT NULL,
    mime_type text NOT NULL,
    size_bytes integer NOT NULL,
    bytes bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    attached_at timestamp with time zone,
    upload_group text
);


--
-- Name: audit_events; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_user_id text,
    event_type text NOT NULL,
    target_type text NOT NULL,
    target_id text,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    initiator_kind text DEFAULT 'person'::text NOT NULL,
    initiator_id text
);


--
-- Name: bot_lifecycle; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.bot_lifecycle (
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    paused_at timestamp with time zone,
    notify text DEFAULT 'all'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brokered_connections; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.brokered_connections (
    provider text NOT NULL,
    app text NOT NULL,
    holder text NOT NULL,
    user_id text,
    vendor_user_id text NOT NULL,
    connected_by text,
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    verified_at timestamp with time zone,
    probe_action text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brokered_connections_holder_check CHECK ((((holder = 'person'::text) AND (user_id IS NOT NULL)) OR ((holder = 'deployment'::text) AND (user_id IS NULL)))),
    CONSTRAINT brokered_connections_provider_check CHECK ((provider = ANY (ARRAY['composio'::text, 'arcade'::text])))
);


--
-- Name: capability_settings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.capability_settings (
    scope_kind text NOT NULL,
    scope_id text DEFAULT ''::text NOT NULL,
    capability text NOT NULL,
    allowed boolean NOT NULL,
    updated_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT capability_settings_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['organization'::text, 'role'::text, 'group'::text])))
);


--
-- Name: channel_agents; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.channel_agents (
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_memberships; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.channel_memberships (
    channel_id text NOT NULL,
    user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    pinned_at timestamp with time zone,
    last_read_at timestamp with time zone
);


--
-- Name: channels; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.channels (
    id text NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    suggested_prompts text[] DEFAULT '{}'::text[] NOT NULL,
    allowed_groups text[] DEFAULT '{}'::text[] NOT NULL,
    package_id uuid,
    override jsonb,
    last_message text,
    last_message_at timestamp with time zone,
    last_message_agent_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    summary text,
    summary_at timestamp with time zone,
    last_message_source_id text
);


--
-- Name: component_exclusions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.component_exclusions (
    component_name text NOT NULL,
    agent_id text NOT NULL,
    withheld_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: component_functions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.component_functions (
    component_name text NOT NULL,
    function_name text NOT NULL,
    granted_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: components; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.components (
    name text NOT NULL,
    title text NOT NULL,
    kind text NOT NULL,
    draft_description text NOT NULL,
    published_description text,
    published boolean DEFAULT false NOT NULL,
    published_at timestamp with time zone,
    updated_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: composio_connections; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.composio_connections (
    toolkit text NOT NULL,
    user_id text NOT NULL,
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    verified_at timestamp with time zone,
    probe_action text
);


--
-- Name: computer_page_frame; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.computer_page_frame (
    computer_id text NOT NULL,
    tool_call_id text NOT NULL,
    url text NOT NULL,
    title text,
    frame text NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: computer_snapshot; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.computer_snapshot (
    computer_id text NOT NULL,
    snapshot_id integer NOT NULL,
    url text NOT NULL,
    elements jsonb NOT NULL,
    taken_at timestamp with time zone DEFAULT now() NOT NULL,
    session text
);


--
-- Name: credentials; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.credentials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind openbot.credential_kind NOT NULL,
    provider text NOT NULL,
    encrypted_value text NOT NULL,
    key_id text NOT NULL,
    metadata jsonb NOT NULL,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: default_opt_outs; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.default_opt_outs (
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    feature text NOT NULL,
    scope text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT default_opt_outs_feature_check CHECK ((feature = ANY (ARRAY['memory_source'::text, 'proactive_research'::text])))
);


--
-- Name: delivery_bindings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.delivery_bindings (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    thread_id text NOT NULL,
    transport text NOT NULL,
    identity text NOT NULL,
    realm text NOT NULL,
    address text NOT NULL,
    mention_id text,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    opted_out_at timestamp with time zone
);


--
-- Name: delivery_challenges; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.delivery_challenges (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    thread_id text NOT NULL,
    transport text NOT NULL,
    address text,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: delivery_inbox; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.delivery_inbox (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    thread_id text NOT NULL,
    binding_id text,
    source text NOT NULL,
    realm text NOT NULL,
    external_id text NOT NULL,
    text text NOT NULL,
    state text DEFAULT 'queued'::text NOT NULL,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: delivery_outbox; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.delivery_outbox (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    thread_id text NOT NULL,
    dedupe_key text NOT NULL,
    binding_id text,
    device_id text,
    transport text NOT NULL,
    text text NOT NULL,
    kind text NOT NULL,
    request_id text,
    state text DEFAULT 'queued'::text NOT NULL,
    provider_id text,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: demonstrations; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.demonstrations (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    bot_id text NOT NULL,
    title text NOT NULL,
    status text DEFAULT 'recording'::text NOT NULL,
    actions jsonb DEFAULT '[]'::jsonb NOT NULL,
    draft jsonb,
    skill_slug text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone
);


--
-- Name: deployment_packages; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.deployment_packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id text NOT NULL,
    source_path text NOT NULL,
    checksum text NOT NULL,
    loaded_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: enterprise_settings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.enterprise_settings (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: group_bot_threads; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.group_bot_threads (
    owner_user_id text NOT NULL,
    channel_id text NOT NULL,
    agent_id text NOT NULL,
    thread_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: group_messages; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.group_messages (
    id text NOT NULL,
    channel_id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text,
    thread_id text,
    text text NOT NULL,
    status text DEFAULT 'completed'::text NOT NULL,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_messages_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'waiting'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: identity_link_challenges; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.identity_link_challenges (
    token_hash text NOT NULL,
    provider text NOT NULL,
    user_id text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: identity_links; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.identity_links (
    id text NOT NULL,
    provider text NOT NULL,
    realm text NOT NULL,
    subject text NOT NULL,
    user_id text NOT NULL,
    handle text,
    verified_by text NOT NULL,
    credential_id uuid,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT identity_links_status_check CHECK ((status = ANY (ARRAY['active'::text, 'needs_reconnect'::text]))),
    CONSTRAINT identity_links_verified_by_check CHECK ((verified_by = ANY (ARRAY['challenge'::text, 'oauth'::text])))
);


--
-- Name: intelligence_channel_mappings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.intelligence_channel_mappings (
    user_id text NOT NULL,
    channel_id text NOT NULL,
    thread_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: learning_settings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.learning_settings (
    id text NOT NULL,
    settings jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: learning_thread_bindings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.learning_thread_bindings (
    user_id text NOT NULL,
    thread_id text NOT NULL,
    agent_id text NOT NULL,
    container_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mcp_servers; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.mcp_servers (
    id text NOT NULL,
    title text NOT NULL,
    vendor text NOT NULL,
    url text NOT NULL,
    provenance text DEFAULT 'first-party'::text NOT NULL,
    credential_id uuid,
    tools_refreshed_at timestamp with time zone,
    last_error text,
    added_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    auth_scheme text,
    logo text,
    account_mode text,
    shared_vendor_user_id text,
    skipped_tools text[],
    CONSTRAINT mcp_servers_account_mode_check CHECK (((account_mode IS NULL) OR (account_mode = ANY (ARRAY['personal'::text, 'shared'::text]))))
);


--
-- Name: mcp_tools; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.mcp_tools (
    server_id text NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    input_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    effect text,
    destructive boolean DEFAULT false NOT NULL,
    version text,
    vendor_name text
);


--
-- Name: mcp_user_credentials; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.mcp_user_credentials (
    server_id text NOT NULL,
    user_id text NOT NULL,
    credential_id uuid NOT NULL,
    scope text NOT NULL,
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: memory_sources; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.memory_sources (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    tool_ref text NOT NULL,
    title text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    sync_status text DEFAULT 'idle'::text NOT NULL,
    sync_error text,
    last_sync_at timestamp with time zone,
    next_sync_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: model_usage; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.model_usage (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text,
    agent_id text NOT NULL,
    thread_id text,
    run_id text,
    model text NOT NULL,
    source text NOT NULL,
    allowed boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT model_usage_source_check CHECK ((source = ANY (ARRAY['configured'::text, 'observed'::text, 'unknown'::text])))
);


--
-- Name: network_policies; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.network_policies (
    scope_kind text NOT NULL,
    scope_id text DEFAULT ''::text NOT NULL,
    mode text NOT NULL,
    rules jsonb DEFAULT '{"entries": []}'::jsonb NOT NULL,
    locked boolean DEFAULT false NOT NULL,
    updated_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT network_policies_mode_check CHECK ((mode = ANY (ARRAY['allow_all'::text, 'defaults_plus_allowlist'::text, 'allowlist_only'::text]))),
    CONSTRAINT network_policies_scope_kind_check CHECK ((scope_kind = ANY (ARRAY['organization'::text, 'group'::text])))
);


--
-- Name: pending_authorizations; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.pending_authorizations (
    actor_id text NOT NULL,
    server_id text NOT NULL,
    action text NOT NULL,
    holder text NOT NULL,
    user_id text,
    vendor_user_id text NOT NULL,
    auth_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    outcome text,
    CONSTRAINT pending_authorizations_completion_check CHECK (((completed_at IS NULL) = (outcome IS NULL))),
    CONSTRAINT pending_authorizations_holder_check CHECK ((((holder = 'person'::text) AND (user_id IS NOT NULL)) OR ((holder = 'deployment'::text) AND (user_id IS NULL)))),
    CONSTRAINT pending_authorizations_outcome_check CHECK (((outcome IS NULL) OR (outcome = ANY (ARRAY['completed'::text, 'failed'::text, 'unreconciled'::text, 'withdrawn'::text])))),
    CONSTRAINT pending_authorizations_user_is_actor_check CHECK (((user_id IS NULL) OR (user_id = actor_id)))
);


--
-- Name: personal_memories; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.personal_memories (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    source_id text,
    external_id text,
    import_digest text,
    content text NOT NULL,
    provenance text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    review_state text DEFAULT 'unreviewed'::text NOT NULL,
    deleted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    formed_by text DEFAULT 'person'::text NOT NULL,
    formed_by_agent_id text,
    source_app text,
    source_ref text,
    source_link text,
    observed_at timestamp with time zone,
    intelligence_memory_id text,
    intelligence_digest text
);


--
-- Name: plugin_grants; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.plugin_grants (
    kind text NOT NULL,
    ref text NOT NULL,
    agent_id text NOT NULL,
    granted_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: proactive_settings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.proactive_settings (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    channel_id text NOT NULL,
    thread_id text NOT NULL,
    focus text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    interval_minutes integer DEFAULT 240 NOT NULL,
    next_run_at timestamp with time zone DEFAULT now() NOT NULL,
    last_run_at timestamp with time zone,
    last_status text DEFAULT 'idle'::text NOT NULL,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT proactive_settings_interval_check CHECK (((interval_minutes >= 60) AND (interval_minutes <= 1440))),
    CONSTRAINT proactive_settings_status_check CHECK ((last_status = ANY (ARRAY['idle'::text, 'running'::text, 'succeeded'::text, 'error'::text])))
);


--
-- Name: proactive_suggestions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.proactive_suggestions (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    setting_id text NOT NULL,
    run_id text NOT NULL,
    title text NOT NULL,
    detail text NOT NULL,
    source_app text,
    source_ref text,
    source_link text,
    status text DEFAULT 'open'::text NOT NULL,
    delivered_at timestamp with time zone,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT proactive_suggestions_status_check CHECK ((status = ANY (ARRAY['open'::text, 'dismissed'::text, 'started'::text])))
);


--
-- Name: push_devices; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.push_devices (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    token text NOT NULL,
    project_id text NOT NULL,
    platform text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: responsibilities; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.responsibilities (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    channel_id text NOT NULL,
    thread_id text NOT NULL,
    title text NOT NULL,
    instruction text NOT NULL,
    success_criteria text NOT NULL,
    status openbot.responsibility_status DEFAULT 'active'::openbot.responsibility_status NOT NULL,
    progress text DEFAULT ''::text NOT NULL,
    last_result text,
    subscriptions jsonb DEFAULT '[]'::jsonb NOT NULL,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: responsibility_events; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.responsibility_events (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    source text NOT NULL,
    external_id text NOT NULL,
    type text NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: responsibility_runs; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.responsibility_runs (
    id text NOT NULL,
    responsibility_id text NOT NULL,
    event_id text NOT NULL,
    status openbot.responsibility_run_status DEFAULT 'queued'::openbot.responsibility_run_status NOT NULL,
    reply_text text,
    error text,
    waiting jsonb,
    continuation jsonb,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: responsibility_source_bindings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.responsibility_source_bindings (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    source text NOT NULL,
    repository text NOT NULL,
    credential_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: responsibility_triggers; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.responsibility_triggers (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    responsibility_id text NOT NULL,
    kind text NOT NULL,
    config jsonb NOT NULL,
    credential_id uuid,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: revoked_access; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.revoked_access (
    email text NOT NULL,
    revoked_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_by text NOT NULL
);


--
-- Name: routine_runs; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.routine_runs (
    id text NOT NULL,
    routine_id text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    status openbot.routine_run_status,
    error text,
    waiting jsonb,
    source text DEFAULT 'schedule'::text NOT NULL
);


--
-- Name: routine_sweeps; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.routine_sweeps (
    id text NOT NULL,
    swept_at timestamp with time zone DEFAULT now() NOT NULL,
    owner text
);


--
-- Name: routines; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.routines (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    agent_id text NOT NULL,
    channel_id text NOT NULL,
    instruction text NOT NULL,
    cron text NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    next_run_at timestamp with time zone NOT NULL,
    last_run_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    enabled_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: sandboxed_components; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.sandboxed_components (
    name text NOT NULL,
    title text NOT NULL,
    draft_description text DEFAULT ''::text NOT NULL,
    draft_html text DEFAULT ''::text NOT NULL,
    draft_css text DEFAULT ''::text NOT NULL,
    draft_js_functions text DEFAULT ''::text NOT NULL,
    draft_argument_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    published_description text,
    published_html text,
    published_css text,
    published_js_functions text,
    published_argument_schema jsonb,
    sample_arguments jsonb DEFAULT '{}'::jsonb NOT NULL,
    revision integer DEFAULT 0 NOT NULL,
    published boolean DEFAULT false NOT NULL,
    published_at timestamp with time zone,
    authored_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: saved_logins; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.saved_logins (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    origin text NOT NULL,
    username text NOT NULL,
    encrypted_password text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone
);


--
-- Name: scim_connection_bindings; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_connection_bindings (
    id text NOT NULL,
    connection_id text NOT NULL,
    connection_key text NOT NULL,
    provisioning_domain_id text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    decommissioned_at timestamp with time zone,
    decommission_status text DEFAULT 'active'::text NOT NULL,
    decommission_cursor_user_id text,
    decommission_reconciled_user_count integer DEFAULT 0 CONSTRAINT scim_connection_bindings_decommission_reconciled_user__not_null NOT NULL,
    decommission_batch_count integer DEFAULT 0 NOT NULL,
    decommission_revision integer DEFAULT 0 NOT NULL,
    decommission_completed_at timestamp with time zone,
    decommission_lease_id text,
    decommission_lease_expires_at timestamp with time zone
);


--
-- Name: scim_group_members; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_group_members (
    id text NOT NULL,
    connection_id text NOT NULL,
    group_id text NOT NULL,
    scim_user_id text NOT NULL,
    membership_key text NOT NULL,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: scim_groups; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_groups (
    id text NOT NULL,
    connection_id text NOT NULL,
    provisioning_domain_id text NOT NULL,
    revision integer DEFAULT 0 NOT NULL,
    display_name text NOT NULL,
    display_name_key text NOT NULL,
    external_id text,
    external_id_key text,
    order_key text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: scim_identity_tombstones; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_identity_tombstones (
    id text NOT NULL,
    connection_id text NOT NULL,
    provisioning_domain_id text NOT NULL,
    external_id text NOT NULL,
    external_id_key text NOT NULL,
    user_id text NOT NULL,
    profile text NOT NULL,
    deleted_at timestamp with time zone NOT NULL
);


--
-- Name: scim_projection_grants; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_projection_grants (
    id text NOT NULL,
    connection_id text NOT NULL,
    provisioning_domain_id text NOT NULL,
    scim_user_id text NOT NULL,
    user_id text NOT NULL,
    source_kind text NOT NULL,
    source_id text NOT NULL,
    source_value text,
    role text NOT NULL,
    grant_key text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: scim_subjects; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_subjects (
    id text NOT NULL,
    user_id text NOT NULL,
    profile_source_id text,
    revision integer NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: scim_users; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.scim_users (
    id text NOT NULL,
    connection_id text NOT NULL,
    provisioning_domain_id text NOT NULL,
    user_id text NOT NULL,
    connection_user_key text NOT NULL,
    user_name text NOT NULL,
    user_name_key text NOT NULL,
    primary_email text NOT NULL,
    work_email_value_index text NOT NULL,
    email_value_index text NOT NULL,
    display_name text NOT NULL,
    formatted_name text NOT NULL,
    given_name text,
    family_name text,
    serialized_emails text NOT NULL,
    serialized_attributes text,
    external_id text,
    external_id_key text,
    active boolean NOT NULL,
    order_key text NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: sessions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.sessions (
    id text NOT NULL,
    user_id text NOT NULL,
    token text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    ip_address text,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: shared_use_approval_members; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.shared_use_approval_members (
    agent_id text NOT NULL,
    server_id text NOT NULL,
    kind text NOT NULL,
    value text NOT NULL,
    CONSTRAINT shared_use_approval_members_kind_check CHECK ((kind = ANY (ARRAY['user'::text, 'group'::text])))
);


--
-- Name: shared_use_approvals; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.shared_use_approvals (
    agent_id text NOT NULL,
    server_id text NOT NULL,
    audience text NOT NULL,
    outside_input boolean NOT NULL,
    approved_by text NOT NULL,
    approved_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT shared_use_approvals_audience_check CHECK ((audience = ANY (ARRAY['owner'::text, 'people'::text, 'team'::text])))
);


--
-- Name: shared_use_requests; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.shared_use_requests (
    id text NOT NULL,
    agent_id text NOT NULL,
    server_id text NOT NULL,
    proposed_audience text NOT NULL,
    proposed_outside_input boolean NOT NULL,
    proposed_members jsonb DEFAULT '[]'::jsonb NOT NULL,
    reason text NOT NULL,
    requested_by text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    decided_by text,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT shared_use_requests_audience_check CHECK ((proposed_audience = ANY (ARRAY['owner'::text, 'people'::text, 'team'::text]))),
    CONSTRAINT shared_use_requests_reason_check CHECK ((reason = ANY (ARRAY['publish'::text, 'trigger'::text, 'grant'::text, 'refused_call'::text]))),
    CONSTRAINT shared_use_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text, 'superseded'::text])))
);


--
-- Name: sign_in_requests; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.sign_in_requests (
    id text NOT NULL,
    owner_user_id text NOT NULL,
    bot_id text NOT NULL,
    origin text NOT NULL,
    reason text,
    status text DEFAULT 'pending'::text NOT NULL,
    method text,
    outcome text,
    thread_id text,
    tool_call_id text,
    control_request_id text,
    continuation jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    resolved_at timestamp with time zone,
    filling_until timestamp with time zone,
    CONSTRAINT sign_in_requests_method_check CHECK (((method IS NULL) OR (method = ANY (ARRAY['typed'::text, 'saved'::text, 'takeover'::text])))),
    CONSTRAINT sign_in_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'filling'::text, 'code_required'::text, 'taken_over'::text, 'signed_in'::text, 'failed'::text, 'cancelled'::text, 'expired'::text])))
);


--
-- Name: skill_tools; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.skill_tools (
    skill_id text NOT NULL,
    ref text NOT NULL,
    declared_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: skills; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.skills (
    id text NOT NULL,
    owner_user_id text,
    slug text NOT NULL,
    title text NOT NULL,
    summary text NOT NULL,
    instructions text NOT NULL,
    origin text DEFAULT 'yours'::text NOT NULL,
    installed_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: sso_providers; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.sso_providers (
    id text NOT NULL,
    issuer text NOT NULL,
    oidc_config text,
    saml_config text,
    user_id text,
    provider_id text NOT NULL,
    organization_id text,
    domain text NOT NULL
);


--
-- Name: team_bot_assignments; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.team_bot_assignments (
    agent_id text NOT NULL,
    group_name text NOT NULL,
    assigned_by text NOT NULL,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: team_bot_audience; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.team_bot_audience (
    agent_id text NOT NULL,
    kind text NOT NULL,
    value text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT team_bot_audience_kind_check CHECK ((kind = ANY (ARRAY['user'::text, 'group'::text])))
);


--
-- Name: team_bot_consent_defaults; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.team_bot_consent_defaults (
    user_id text NOT NULL,
    server_id text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: team_bot_consents; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.team_bot_consents (
    user_id text NOT NULL,
    agent_id text NOT NULL,
    server_id text NOT NULL,
    decision text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT team_bot_consents_decision_check CHECK ((decision = ANY (ARRAY['always'::text, 'once'::text])))
);


--
-- Name: team_bot_publications; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.team_bot_publications (
    agent_id text NOT NULL,
    published_by text NOT NULL,
    audience text NOT NULL,
    published_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT team_bot_publications_audience_check CHECK ((audience = ANY (ARRAY['team'::text, 'people'::text])))
);


--
-- Name: update_routing_preferences; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.update_routing_preferences (
    owner_user_id text NOT NULL,
    kind text NOT NULL,
    transports text[] DEFAULT '{}'::text[] NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_instructions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.user_instructions (
    user_id text NOT NULL,
    instructions text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_roles; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.user_roles (
    user_id text NOT NULL,
    role openbot.role NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.users (
    id text NOT NULL,
    email text NOT NULL,
    name text,
    image text,
    email_verified boolean DEFAULT false NOT NULL,
    groups text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    onboarding_step integer DEFAULT 0 NOT NULL,
    onboarding_completed_at timestamp with time zone,
    last_signed_in_at timestamp with time zone,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: verifications; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.verifications (
    id text NOT NULL,
    identifier text NOT NULL,
    value text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: voice_sessions; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.voice_sessions (
    id text NOT NULL,
    channel_id text NOT NULL,
    user_id text NOT NULL,
    anchor_message_id text,
    started_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone NOT NULL,
    duration_seconds integer NOT NULL,
    transcript jsonb NOT NULL,
    summary text,
    summary_status text DEFAULT 'failed'::text NOT NULL,
    CONSTRAINT voice_sessions_duration_check CHECK ((duration_seconds >= 0)),
    CONSTRAINT voice_sessions_summary_check CHECK ((((summary_status = 'ready'::text) AND (summary IS NOT NULL)) OR ((summary_status = 'failed'::text) AND (summary IS NULL))))
);


--
-- Name: work_items; Type: TABLE; Schema: openbot; Owner: -
--

CREATE TABLE openbot.work_items (
    kind text NOT NULL,
    key text NOT NULL,
    run_at timestamp with time zone DEFAULT now() NOT NULL,
    claimed_by text,
    lease_until timestamp with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    finished_at timestamp with time zone,
    last_error text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: __drizzle_migrations id; Type: DEFAULT; Schema: drizzle; Owner: -
--

ALTER TABLE ONLY drizzle.__drizzle_migrations ALTER COLUMN id SET DEFAULT nextval('drizzle.__drizzle_migrations_id_seq'::regclass);


--
-- Data for Name: __drizzle_migrations; Type: TABLE DATA; Schema: drizzle; Owner: -
--

INSERT INTO drizzle.__drizzle_migrations VALUES (1, 'c012c2b106de04e42107a7f6a7dea12778a077c370c48d8cd1d35bc642545c3c', 1786891733850);
INSERT INTO drizzle.__drizzle_migrations VALUES (2, '1af5c2a0b92f1eba0752be2e415c7690984cf1e136ae60da3c7c60d60a2c5c4c', 1787198911059);
INSERT INTO drizzle.__drizzle_migrations VALUES (3, '8f1b4f51b8429a44947e281b77444967a4e487e4e7ae36640d2e51f485a8057e', 1787275307382);
INSERT INTO drizzle.__drizzle_migrations VALUES (4, 'b4cb926b3ccb5a91fab72cd60e7b237931046ac8379814a887a0de875bb713d0', 1787275307621);
INSERT INTO drizzle.__drizzle_migrations VALUES (5, '49a4cd7271ec0a54fa4ac6d4ec8edfab53a52229fdb3ec50d2044067d13cbb5d', 1787324562029);
INSERT INTO drizzle.__drizzle_migrations VALUES (6, '9e84fc240ce491eb22a32cfa9d04fb0d5f9a3fef990ab9bc4e51e13d24a7489a', 1787324600000);
INSERT INTO drizzle.__drizzle_migrations VALUES (7, '598ed7d1d53b351f917eea68ad42463d4cc878cb54469bfa5f4957503723a64f', 1787330336906);
INSERT INTO drizzle.__drizzle_migrations VALUES (8, '82d6aa540927215ee18a0199af4363e1a0c355a1e9d18660595ad332c2dfeed1', 1787330552602);
INSERT INTO drizzle.__drizzle_migrations VALUES (9, 'ce3df0c2747ad6a2298ec02d2ed1bd99f05420a68a16f8f25c457a628a3d1f57', 1787339895173);
INSERT INTO drizzle.__drizzle_migrations VALUES (10, 'bedeaedb5c9dd1f7167bc5005b2a2c3b6007bc27aa8a370ff951b42d3a3963f3', 1787342459868);
INSERT INTO drizzle.__drizzle_migrations VALUES (11, '7226750bc2ccf1d42007a1462242f649cacd4ac034aac06d0b72683893f12bc3', 1787357412066);
INSERT INTO drizzle.__drizzle_migrations VALUES (12, '2ec6ab9176f1659e7f7f982847e1572123ff263bcf5554f043944c76009e7d8d', 1787358347113);
INSERT INTO drizzle.__drizzle_migrations VALUES (13, '2abf9b57cdbc0f26c85b3abcc7bf10d2458bfd63539bedbd403d0e6799075496', 1787359000000);
INSERT INTO drizzle.__drizzle_migrations VALUES (14, 'b3cd0f854e92bc4f4b020429b204d0bdc9f615a4c1da9ed4b83ce3c33624a273', 1787380044372);
INSERT INTO drizzle.__drizzle_migrations VALUES (15, '0e6346166d69dc4892f0c13749e29e6a95439d1c64f8e8c478269ee6134adaf6', 1787380104372);
INSERT INTO drizzle.__drizzle_migrations VALUES (16, '53db3a32c7b41a0557afb467dbfbb087ec08e4112d03c5469fc5bd439aec6b2b', 1787525879804);
INSERT INTO drizzle.__drizzle_migrations VALUES (17, '3d046be6d20fd591e234fab4b9a8ce96ac24246e7013dc0cfc7a1eb6190070a4', 1787581516968);
INSERT INTO drizzle.__drizzle_migrations VALUES (18, '14daa9ee4847ba00276a2e069e98e53470463bc7f823a6f5af1f123555166414', 1787684818682);
INSERT INTO drizzle.__drizzle_migrations VALUES (19, '796931a11836c34583703a51b5124a909c17562a9830df13016279e6c356a0de', 1787688017645);
INSERT INTO drizzle.__drizzle_migrations VALUES (20, '760ef62ab8b5c7c9103ad2109f0eb481d80b9ce75d30ec0f5819011422ac2eab', 1787744867526);
INSERT INTO drizzle.__drizzle_migrations VALUES (21, '972945546eaadf59f6f1150c17621041abd7c46e6f77c18c807bda58a8b2a1be', 1787761381038);
INSERT INTO drizzle.__drizzle_migrations VALUES (22, '9ec3c3316265de468985cfff41345df8bc2c49906e49a91abee145ce9fd1b5bc', 1787767359748);
INSERT INTO drizzle.__drizzle_migrations VALUES (23, 'f10adcdb483846f920f1097754509301f68fcdbf39b45c95887fdb784ca845a7', 1787841150017);
INSERT INTO drizzle.__drizzle_migrations VALUES (24, '5c3d841d3a726b7388bd7f9bd00a6137661b0390fbf9d5bbff8ceb2b10c3824e', 1787841174859);
INSERT INTO drizzle.__drizzle_migrations VALUES (25, '063f214433e198a79a36c03867687de9cce75f324f5fd5c75a3ab5f393b8fec7', 1787926466892);
INSERT INTO drizzle.__drizzle_migrations VALUES (26, '98e0a2f329ee8e8e574ff7bd5c028c4dd2c67b303e89bef6ac5ac06d4e5d10ae', 1787926472382);
INSERT INTO drizzle.__drizzle_migrations VALUES (27, 'e8f283bfdec412700a829fbef724fd37627e74e73f225a19672a551284005740', 1788271863590);
INSERT INTO drizzle.__drizzle_migrations VALUES (28, '95bda3c518864d1c9ee10fac7aef3f239864d8a4ee6b6b51d5d4d7fa6cd45702', 1788543624826);
INSERT INTO drizzle.__drizzle_migrations VALUES (29, '29161fcc577cd5648ea58591a41e1ac86122234411faf72e2744907149024170', 1788548093782);
INSERT INTO drizzle.__drizzle_migrations VALUES (30, '65ab77f383f965f5dcfd19f5178c541dbd89177a52ad5c16394def86e23b2b39', 1788911713422);
INSERT INTO drizzle.__drizzle_migrations VALUES (31, '1df188e0f2dbd040b86fa6f5abe30c8716f9dfd62336a3a52ccd64984a3d6ce8', 1788989179914);
INSERT INTO drizzle.__drizzle_migrations VALUES (32, '48bfef3a2bc3514561b2b061eeaededee50cc9340b64d4935a51834413d34f33', 1788990260165);
INSERT INTO drizzle.__drizzle_migrations VALUES (33, '5e91e97882c2288335c75dac4aadde802fcc25accce87bc16fdae68725017429', 1789059537115);
INSERT INTO drizzle.__drizzle_migrations VALUES (34, '507d804ef613a48fac5ad80c0b4834d300b582acaf7141e3e1ec9666ac60ab37', 1789066859018);
INSERT INTO drizzle.__drizzle_migrations VALUES (35, 'a5cdef00cd2ad6561747771d1ff76109d93851462594bb1cd7f74d1bd5d67b1c', 1789162066485);
INSERT INTO drizzle.__drizzle_migrations VALUES (36, '9320107cfc3b26aaaafea0ef41d5462abac4830b62caac91e4ee371bb88691ee', 1789162076466);
INSERT INTO drizzle.__drizzle_migrations VALUES (37, 'e304b5820b25c17b62b476c16043fd272da5d27dc4a7fad61ac090a8943e4c23', 1789182921776);
INSERT INTO drizzle.__drizzle_migrations VALUES (38, 'fdb4f11e3df723ef6b4e6fc965fecbde5ab773f735894f9cd41b9e3ec32a4c4d', 1789389068825);
INSERT INTO drizzle.__drizzle_migrations VALUES (39, 'd6e7e773b8c4905f1c5a820604dacaf2391ddb5be2415f0ba33bddcaa2fee79d', 1789389080686);
INSERT INTO drizzle.__drizzle_migrations VALUES (40, '9470a9843fb6549f239124364fe1252bc598e00fd1206f3b23e4a09b871b3db1', 1789389088622);
INSERT INTO drizzle.__drizzle_migrations VALUES (41, '58bdca801c50d5ed0813f27aec0f86a6d75f9660e6f4e6e6bb8c35a1790f5461', 1789495814957);
INSERT INTO drizzle.__drizzle_migrations VALUES (42, '4ddd7cf4aba33feab9cd31b3745a92932d89dc07256e04bc5928f7e7eb5702fe', 1789540094910);
INSERT INTO drizzle.__drizzle_migrations VALUES (43, 'f4ecdb1558c6b803a899530eac0425e1e7dfc5e83b144910d79a2a362ed3cfc1', 1789569523560);
INSERT INTO drizzle.__drizzle_migrations VALUES (44, '5aba8e48317aa3436ef294bc41b0221432c6f8ad81e8280f73ae32b62c39f4a4', 1789579982431);
INSERT INTO drizzle.__drizzle_migrations VALUES (45, 'ed7e30336a33d4675aa47f9ce51c4911dbead8f7920aebf8aac941e777c34485', 1790035200000);
INSERT INTO drizzle.__drizzle_migrations VALUES (46, '70eaf54c38fc1458e7ce22c1ab76d379e380343657e51ac6fdd6e014b5a19e21', 1790164423415);
INSERT INTO drizzle.__drizzle_migrations VALUES (47, '1730fad1c8ec7ec4c370ae5e984dfb66cdf02f286c59498cb7315c8546ce3232', 1790447917102);
INSERT INTO drizzle.__drizzle_migrations VALUES (48, '61f5afcd5e0a8caeedd3341656c7b8415648284d0ed4e74b403516a664c9b5b4', 1790572443740);
INSERT INTO drizzle.__drizzle_migrations VALUES (49, 'cff1da1f9417b3a7aee28ea35a54d142e09c95e84f90b0931bcbcf34fa5f98e9', 1790730431917);
INSERT INTO drizzle.__drizzle_migrations VALUES (50, 'a4c70530630adaf5a9eb5f29b2b5ace33535f5ccd85c8143db02f093a948756d', 1790733068188);
INSERT INTO drizzle.__drizzle_migrations VALUES (51, 'bba7b02bffa02d2ad73fdad51852c8c1fc6e4c2f63f16130fa23ca44fa5619f1', 1790872515140);
INSERT INTO drizzle.__drizzle_migrations VALUES (52, 'c6aadc52be555e831550d0f396e94e83cdfe4c4f8cbdf1507ca944e018e8ae03', 1790939356628);
INSERT INTO drizzle.__drizzle_migrations VALUES (53, 'e82b834c7a826b0ec7c3f9a85f7422400bea5463d9dbb0e78e9f968e4c9ee6ac', 1791396757748);
INSERT INTO drizzle.__drizzle_migrations VALUES (54, 'e924de8b52f8ab4191d4e5e80fb60493002cdbbe118a6e441b4024856279f4e1', 1791547580808);
INSERT INTO drizzle.__drizzle_migrations VALUES (55, 'ad7c9a0d20e377cab8b4ee72334e5c52ad754811b2bbc64da197beedcdad39dc', 1791832775550);
INSERT INTO drizzle.__drizzle_migrations VALUES (56, '64795d5bd5fcc7e5c00050d45cbfb344ccb98b53c28d9aabf9d30380a46c4e1d', 1791841282662);
INSERT INTO drizzle.__drizzle_migrations VALUES (57, '357524a945a226f8d730c37c2e2926fe7190feb3e12477e1c9b3c452f958be3e', 1791866936937);
INSERT INTO drizzle.__drizzle_migrations VALUES (58, '65c8f3582f40edd8f6cc08997d966e5ce19540f96efff7bf9a151573de44068a', 1792099944352);
INSERT INTO drizzle.__drizzle_migrations VALUES (59, '3f88248997e35a2e2d42405f7521133c51893518cd953970408a81903152d666', 1792099950842);
INSERT INTO drizzle.__drizzle_migrations VALUES (60, 'cb121bb37e1f4d0e2e10f6633819f5335b588619154e32793ec8a62a357d7dfc', 1792251361575);
INSERT INTO drizzle.__drizzle_migrations VALUES (61, '11603ab12671079b39a1a5cd7a9a40e8ea3d50c0b83170ff9417639e77668fca', 1792608466985);


--
-- Data for Name: threads; Type: TABLE DATA; Schema: jevie_runtime; Owner: -
--



--
-- Data for Name: accounts; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: action_policy; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: action_records; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: agent_preferences; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: agent_profiles; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: agents; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: app_access_requests; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: approval_preferences; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: approval_requests; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: approval_rules; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: approval_team_rules; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: approval_team_settings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: attachments; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: audit_events; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: bot_lifecycle; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: brokered_connections; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: capability_settings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: channel_agents; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: channel_memberships; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: channels; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: component_exclusions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: component_functions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: components; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: composio_connections; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: computer_page_frame; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: computer_snapshot; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: credentials; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: default_opt_outs; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: delivery_bindings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: delivery_challenges; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: delivery_inbox; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: delivery_outbox; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: demonstrations; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: deployment_packages; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: enterprise_settings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: group_bot_threads; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: group_messages; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: identity_link_challenges; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: identity_links; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: intelligence_channel_mappings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: learning_settings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: learning_thread_bindings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: mcp_servers; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: mcp_tools; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: mcp_user_credentials; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: memory_sources; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: model_usage; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: network_policies; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: pending_authorizations; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: personal_memories; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: plugin_grants; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: proactive_settings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: proactive_suggestions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: push_devices; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: responsibilities; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: responsibility_events; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: responsibility_runs; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: responsibility_source_bindings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: responsibility_triggers; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: revoked_access; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: routine_runs; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: routine_sweeps; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: routines; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: sandboxed_components; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: saved_logins; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_connection_bindings; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_group_members; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_groups; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_identity_tombstones; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_projection_grants; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_subjects; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: scim_users; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: sessions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: shared_use_approval_members; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: shared_use_approvals; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: shared_use_requests; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: sign_in_requests; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: skill_tools; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: skills; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: sso_providers; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: team_bot_assignments; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: team_bot_audience; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: team_bot_consent_defaults; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: team_bot_consents; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: team_bot_publications; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: update_routing_preferences; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: user_instructions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: user_roles; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: users; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: verifications; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: voice_sessions; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Data for Name: work_items; Type: TABLE DATA; Schema: openbot; Owner: -
--



--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE SET; Schema: drizzle; Owner: -
--

SELECT pg_catalog.setval('drizzle.__drizzle_migrations_id_seq', 61, true);


--
-- Name: __drizzle_migrations __drizzle_migrations_pkey; Type: CONSTRAINT; Schema: drizzle; Owner: -
--

ALTER TABLE ONLY drizzle.__drizzle_migrations
    ADD CONSTRAINT __drizzle_migrations_pkey PRIMARY KEY (id);


--
-- Name: threads threads_pkey; Type: CONSTRAINT; Schema: jevie_runtime; Owner: -
--

ALTER TABLE ONLY jevie_runtime.threads
    ADD CONSTRAINT threads_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: action_policy action_policy_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.action_policy
    ADD CONSTRAINT action_policy_pkey PRIMARY KEY (id);


--
-- Name: action_records action_records_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.action_records
    ADD CONSTRAINT action_records_pkey PRIMARY KEY (id);


--
-- Name: agent_preferences agent_preferences_user_id_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_preferences
    ADD CONSTRAINT agent_preferences_user_id_agent_id_pk PRIMARY KEY (user_id, agent_id);


--
-- Name: agent_profiles agent_profiles_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_profiles
    ADD CONSTRAINT agent_profiles_pkey PRIMARY KEY (agent_id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: app_access_requests app_access_requests_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.app_access_requests
    ADD CONSTRAINT app_access_requests_pkey PRIMARY KEY (id);


--
-- Name: approval_preferences approval_preferences_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_preferences
    ADD CONSTRAINT approval_preferences_pkey PRIMARY KEY (owner_user_id);


--
-- Name: approval_requests approval_requests_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_requests
    ADD CONSTRAINT approval_requests_pkey PRIMARY KEY (id);


--
-- Name: approval_rules approval_rules_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_rules
    ADD CONSTRAINT approval_rules_pkey PRIMARY KEY (id);


--
-- Name: approval_team_rules approval_team_rules_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_team_rules
    ADD CONSTRAINT approval_team_rules_pkey PRIMARY KEY (id);


--
-- Name: approval_team_settings approval_team_settings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_team_settings
    ADD CONSTRAINT approval_team_settings_pkey PRIMARY KEY (id);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: bot_lifecycle bot_lifecycle_owner_user_id_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.bot_lifecycle
    ADD CONSTRAINT bot_lifecycle_owner_user_id_agent_id_pk PRIMARY KEY (owner_user_id, agent_id);


--
-- Name: capability_settings capability_settings_scope_kind_scope_id_capability_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.capability_settings
    ADD CONSTRAINT capability_settings_scope_kind_scope_id_capability_pk PRIMARY KEY (scope_kind, scope_id, capability);


--
-- Name: channel_agents channel_agents_channel_id_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_agents
    ADD CONSTRAINT channel_agents_channel_id_agent_id_pk PRIMARY KEY (channel_id, agent_id);


--
-- Name: channel_memberships channel_memberships_channel_id_user_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_memberships
    ADD CONSTRAINT channel_memberships_channel_id_user_id_pk PRIMARY KEY (channel_id, user_id);


--
-- Name: channels channels_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channels
    ADD CONSTRAINT channels_pkey PRIMARY KEY (id);


--
-- Name: component_exclusions component_exclusions_component_name_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.component_exclusions
    ADD CONSTRAINT component_exclusions_component_name_agent_id_pk PRIMARY KEY (component_name, agent_id);


--
-- Name: component_functions component_functions_component_name_function_name_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.component_functions
    ADD CONSTRAINT component_functions_component_name_function_name_pk PRIMARY KEY (component_name, function_name);


--
-- Name: components components_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.components
    ADD CONSTRAINT components_pkey PRIMARY KEY (name);


--
-- Name: composio_connections composio_connections_toolkit_user_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.composio_connections
    ADD CONSTRAINT composio_connections_toolkit_user_id_pk PRIMARY KEY (toolkit, user_id);


--
-- Name: computer_page_frame computer_page_frame_computer_id_tool_call_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.computer_page_frame
    ADD CONSTRAINT computer_page_frame_computer_id_tool_call_id_pk PRIMARY KEY (computer_id, tool_call_id);


--
-- Name: computer_snapshot computer_snapshot_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.computer_snapshot
    ADD CONSTRAINT computer_snapshot_pkey PRIMARY KEY (computer_id);


--
-- Name: credentials credentials_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.credentials
    ADD CONSTRAINT credentials_pkey PRIMARY KEY (id);


--
-- Name: default_opt_outs default_opt_outs_owner_user_id_agent_id_feature_scope_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.default_opt_outs
    ADD CONSTRAINT default_opt_outs_owner_user_id_agent_id_feature_scope_pk PRIMARY KEY (owner_user_id, agent_id, feature, scope);


--
-- Name: delivery_bindings delivery_bindings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_bindings
    ADD CONSTRAINT delivery_bindings_pkey PRIMARY KEY (id);


--
-- Name: delivery_challenges delivery_challenges_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_challenges
    ADD CONSTRAINT delivery_challenges_pkey PRIMARY KEY (id);


--
-- Name: delivery_inbox delivery_inbox_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_inbox
    ADD CONSTRAINT delivery_inbox_pkey PRIMARY KEY (id);


--
-- Name: delivery_outbox delivery_outbox_dedupe_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_outbox
    ADD CONSTRAINT delivery_outbox_dedupe_key_unique UNIQUE (dedupe_key);


--
-- Name: delivery_outbox delivery_outbox_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_outbox
    ADD CONSTRAINT delivery_outbox_pkey PRIMARY KEY (id);


--
-- Name: demonstrations demonstrations_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.demonstrations
    ADD CONSTRAINT demonstrations_pkey PRIMARY KEY (id);


--
-- Name: deployment_packages deployment_packages_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.deployment_packages
    ADD CONSTRAINT deployment_packages_pkey PRIMARY KEY (id);


--
-- Name: deployment_packages deployment_packages_tenant_id_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.deployment_packages
    ADD CONSTRAINT deployment_packages_tenant_id_unique UNIQUE (tenant_id);


--
-- Name: enterprise_settings enterprise_settings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.enterprise_settings
    ADD CONSTRAINT enterprise_settings_pkey PRIMARY KEY (key);


--
-- Name: group_bot_threads group_bot_threads_owner_user_id_channel_id_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_bot_threads
    ADD CONSTRAINT group_bot_threads_owner_user_id_channel_id_agent_id_pk PRIMARY KEY (owner_user_id, channel_id, agent_id);


--
-- Name: group_messages group_messages_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_messages
    ADD CONSTRAINT group_messages_pkey PRIMARY KEY (id);


--
-- Name: identity_link_challenges identity_link_challenges_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.identity_link_challenges
    ADD CONSTRAINT identity_link_challenges_pkey PRIMARY KEY (token_hash);


--
-- Name: identity_links identity_links_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.identity_links
    ADD CONSTRAINT identity_links_pkey PRIMARY KEY (id);


--
-- Name: intelligence_channel_mappings intelligence_channel_mappings_user_id_channel_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.intelligence_channel_mappings
    ADD CONSTRAINT intelligence_channel_mappings_user_id_channel_id_pk PRIMARY KEY (user_id, channel_id);


--
-- Name: learning_settings learning_settings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.learning_settings
    ADD CONSTRAINT learning_settings_pkey PRIMARY KEY (id);


--
-- Name: learning_thread_bindings learning_thread_bindings_user_id_thread_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.learning_thread_bindings
    ADD CONSTRAINT learning_thread_bindings_user_id_thread_id_pk PRIMARY KEY (user_id, thread_id);


--
-- Name: mcp_servers mcp_servers_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_servers
    ADD CONSTRAINT mcp_servers_pkey PRIMARY KEY (id);


--
-- Name: mcp_tools mcp_tools_server_id_name_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_tools
    ADD CONSTRAINT mcp_tools_server_id_name_pk PRIMARY KEY (server_id, name);


--
-- Name: mcp_user_credentials mcp_user_credentials_server_id_user_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_user_credentials
    ADD CONSTRAINT mcp_user_credentials_server_id_user_id_pk PRIMARY KEY (server_id, user_id);


--
-- Name: memory_sources memory_sources_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.memory_sources
    ADD CONSTRAINT memory_sources_pkey PRIMARY KEY (id);


--
-- Name: model_usage model_usage_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.model_usage
    ADD CONSTRAINT model_usage_pkey PRIMARY KEY (id);


--
-- Name: network_policies network_policies_scope_kind_scope_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.network_policies
    ADD CONSTRAINT network_policies_scope_kind_scope_id_pk PRIMARY KEY (scope_kind, scope_id);


--
-- Name: pending_authorizations pending_authorizations_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.pending_authorizations
    ADD CONSTRAINT pending_authorizations_pkey PRIMARY KEY (actor_id);


--
-- Name: personal_memories personal_memories_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.personal_memories
    ADD CONSTRAINT personal_memories_pkey PRIMARY KEY (id);


--
-- Name: plugin_grants plugin_grants_kind_ref_agent_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.plugin_grants
    ADD CONSTRAINT plugin_grants_kind_ref_agent_id_pk PRIMARY KEY (kind, ref, agent_id);


--
-- Name: proactive_settings proactive_settings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_settings
    ADD CONSTRAINT proactive_settings_pkey PRIMARY KEY (id);


--
-- Name: proactive_suggestions proactive_suggestions_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_suggestions
    ADD CONSTRAINT proactive_suggestions_pkey PRIMARY KEY (id);


--
-- Name: push_devices push_devices_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.push_devices
    ADD CONSTRAINT push_devices_pkey PRIMARY KEY (id);


--
-- Name: push_devices push_devices_token_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.push_devices
    ADD CONSTRAINT push_devices_token_unique UNIQUE (token);


--
-- Name: responsibilities responsibilities_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibilities
    ADD CONSTRAINT responsibilities_pkey PRIMARY KEY (id);


--
-- Name: responsibility_events responsibility_events_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_events
    ADD CONSTRAINT responsibility_events_pkey PRIMARY KEY (id);


--
-- Name: responsibility_runs responsibility_runs_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_runs
    ADD CONSTRAINT responsibility_runs_pkey PRIMARY KEY (id);


--
-- Name: responsibility_source_bindings responsibility_source_bindings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_source_bindings
    ADD CONSTRAINT responsibility_source_bindings_pkey PRIMARY KEY (id);


--
-- Name: responsibility_triggers responsibility_triggers_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_triggers
    ADD CONSTRAINT responsibility_triggers_pkey PRIMARY KEY (id);


--
-- Name: revoked_access revoked_access_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.revoked_access
    ADD CONSTRAINT revoked_access_pkey PRIMARY KEY (email);


--
-- Name: routine_runs routine_runs_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routine_runs
    ADD CONSTRAINT routine_runs_pkey PRIMARY KEY (id);


--
-- Name: routine_sweeps routine_sweeps_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routine_sweeps
    ADD CONSTRAINT routine_sweeps_pkey PRIMARY KEY (id);


--
-- Name: routines routines_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routines
    ADD CONSTRAINT routines_pkey PRIMARY KEY (id);


--
-- Name: sandboxed_components sandboxed_components_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sandboxed_components
    ADD CONSTRAINT sandboxed_components_pkey PRIMARY KEY (name);


--
-- Name: saved_logins saved_logins_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.saved_logins
    ADD CONSTRAINT saved_logins_pkey PRIMARY KEY (id);


--
-- Name: scim_connection_bindings scim_connection_bindings_connection_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_connection_bindings
    ADD CONSTRAINT scim_connection_bindings_connection_key_unique UNIQUE (connection_key);


--
-- Name: scim_connection_bindings scim_connection_bindings_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_connection_bindings
    ADD CONSTRAINT scim_connection_bindings_pkey PRIMARY KEY (id);


--
-- Name: scim_group_members scim_group_members_membership_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_group_members
    ADD CONSTRAINT scim_group_members_membership_key_unique UNIQUE (membership_key);


--
-- Name: scim_group_members scim_group_members_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_group_members
    ADD CONSTRAINT scim_group_members_pkey PRIMARY KEY (id);


--
-- Name: scim_groups scim_groups_display_name_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_groups
    ADD CONSTRAINT scim_groups_display_name_key_unique UNIQUE (display_name_key);


--
-- Name: scim_groups scim_groups_external_id_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_groups
    ADD CONSTRAINT scim_groups_external_id_key_unique UNIQUE (external_id_key);


--
-- Name: scim_groups scim_groups_order_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_groups
    ADD CONSTRAINT scim_groups_order_key_unique UNIQUE (order_key);


--
-- Name: scim_groups scim_groups_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_groups
    ADD CONSTRAINT scim_groups_pkey PRIMARY KEY (id);


--
-- Name: scim_identity_tombstones scim_identity_tombstones_external_id_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_identity_tombstones
    ADD CONSTRAINT scim_identity_tombstones_external_id_key_unique UNIQUE (external_id_key);


--
-- Name: scim_identity_tombstones scim_identity_tombstones_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_identity_tombstones
    ADD CONSTRAINT scim_identity_tombstones_pkey PRIMARY KEY (id);


--
-- Name: scim_projection_grants scim_projection_grants_grant_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_projection_grants
    ADD CONSTRAINT scim_projection_grants_grant_key_unique UNIQUE (grant_key);


--
-- Name: scim_projection_grants scim_projection_grants_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_projection_grants
    ADD CONSTRAINT scim_projection_grants_pkey PRIMARY KEY (id);


--
-- Name: scim_subjects scim_subjects_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_subjects
    ADD CONSTRAINT scim_subjects_pkey PRIMARY KEY (id);


--
-- Name: scim_subjects scim_subjects_user_id_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_subjects
    ADD CONSTRAINT scim_subjects_user_id_unique UNIQUE (user_id);


--
-- Name: scim_users scim_users_connection_user_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_connection_user_key_unique UNIQUE (connection_user_key);


--
-- Name: scim_users scim_users_external_id_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_external_id_key_unique UNIQUE (external_id_key);


--
-- Name: scim_users scim_users_order_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_order_key_unique UNIQUE (order_key);


--
-- Name: scim_users scim_users_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_pkey PRIMARY KEY (id);


--
-- Name: scim_users scim_users_user_name_key_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_user_name_key_unique UNIQUE (user_name_key);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_token_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sessions
    ADD CONSTRAINT sessions_token_unique UNIQUE (token);


--
-- Name: shared_use_approval_members shared_use_approval_members_agent_id_server_id_kind_value_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_approval_members
    ADD CONSTRAINT shared_use_approval_members_agent_id_server_id_kind_value_pk PRIMARY KEY (agent_id, server_id, kind, value);


--
-- Name: shared_use_approvals shared_use_approvals_agent_id_server_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_approvals
    ADD CONSTRAINT shared_use_approvals_agent_id_server_id_pk PRIMARY KEY (agent_id, server_id);


--
-- Name: shared_use_requests shared_use_requests_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_requests
    ADD CONSTRAINT shared_use_requests_pkey PRIMARY KEY (id);


--
-- Name: sign_in_requests sign_in_requests_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sign_in_requests
    ADD CONSTRAINT sign_in_requests_pkey PRIMARY KEY (id);


--
-- Name: skill_tools skill_tools_skill_id_ref_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.skill_tools
    ADD CONSTRAINT skill_tools_skill_id_ref_pk PRIMARY KEY (skill_id, ref);


--
-- Name: skills skills_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.skills
    ADD CONSTRAINT skills_pkey PRIMARY KEY (id);


--
-- Name: sso_providers sso_providers_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sso_providers
    ADD CONSTRAINT sso_providers_pkey PRIMARY KEY (id);


--
-- Name: sso_providers sso_providers_provider_id_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sso_providers
    ADD CONSTRAINT sso_providers_provider_id_unique UNIQUE (provider_id);


--
-- Name: team_bot_assignments team_bot_assignments_agent_id_group_name_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_assignments
    ADD CONSTRAINT team_bot_assignments_agent_id_group_name_pk PRIMARY KEY (agent_id, group_name);


--
-- Name: team_bot_audience team_bot_audience_agent_id_kind_value_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_audience
    ADD CONSTRAINT team_bot_audience_agent_id_kind_value_pk PRIMARY KEY (agent_id, kind, value);


--
-- Name: team_bot_consent_defaults team_bot_consent_defaults_user_id_server_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_consent_defaults
    ADD CONSTRAINT team_bot_consent_defaults_user_id_server_id_pk PRIMARY KEY (user_id, server_id);


--
-- Name: team_bot_consents team_bot_consents_user_id_agent_id_server_id_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_consents
    ADD CONSTRAINT team_bot_consents_user_id_agent_id_server_id_pk PRIMARY KEY (user_id, agent_id, server_id);


--
-- Name: team_bot_publications team_bot_publications_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_publications
    ADD CONSTRAINT team_bot_publications_pkey PRIMARY KEY (agent_id);


--
-- Name: update_routing_preferences update_routing_preferences_owner_user_id_kind_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.update_routing_preferences
    ADD CONSTRAINT update_routing_preferences_owner_user_id_kind_pk PRIMARY KEY (owner_user_id, kind);


--
-- Name: user_instructions user_instructions_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.user_instructions
    ADD CONSTRAINT user_instructions_pkey PRIMARY KEY (user_id);


--
-- Name: user_roles user_roles_user_id_role_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.user_roles
    ADD CONSTRAINT user_roles_user_id_role_pk PRIMARY KEY (user_id, role);


--
-- Name: users users_email_unique; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.users
    ADD CONSTRAINT users_email_unique UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: verifications verifications_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.verifications
    ADD CONSTRAINT verifications_pkey PRIMARY KEY (id);


--
-- Name: voice_sessions voice_sessions_pkey; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.voice_sessions
    ADD CONSTRAINT voice_sessions_pkey PRIMARY KEY (id);


--
-- Name: work_items work_items_kind_key_pk; Type: CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.work_items
    ADD CONSTRAINT work_items_kind_key_pk PRIMARY KEY (kind, key);


--
-- Name: jevie_threads_owner_updated_idx; Type: INDEX; Schema: jevie_runtime; Owner: -
--

CREATE INDEX jevie_threads_owner_updated_idx ON jevie_runtime.threads USING btree (owner_id, updated_at DESC);


--
-- Name: accounts_provider_account_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX accounts_provider_account_idx ON openbot.accounts USING btree (provider_id, account_id);


--
-- Name: action_records_bot_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX action_records_bot_idx ON openbot.action_records USING btree (bot_id, created_at);


--
-- Name: action_records_created_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX action_records_created_idx ON openbot.action_records USING btree (created_at);


--
-- Name: agent_profiles_visibility_deleted_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX agent_profiles_visibility_deleted_idx ON openbot.agent_profiles USING btree (visibility, deleted_at);


--
-- Name: app_access_requests_pending_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX app_access_requests_pending_idx ON openbot.app_access_requests USING btree (requested_by, app_key, COALESCE(agent_id, ''::text), kind) WHERE (status = 'pending'::text);


--
-- Name: app_access_requests_status_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX app_access_requests_status_idx ON openbot.app_access_requests USING btree (status, app_key);


--
-- Name: approval_requests_action_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX approval_requests_action_idx ON openbot.approval_requests USING btree (owner_user_id, run_id, tool_call_id);


--
-- Name: approval_requests_inbox_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX approval_requests_inbox_idx ON openbot.approval_requests USING btree (owner_user_id, status);


--
-- Name: approval_rules_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX approval_rules_owner_idx ON openbot.approval_rules USING btree (owner_user_id);


--
-- Name: attachments_channel_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX attachments_channel_idx ON openbot.attachments USING btree (channel_id);


--
-- Name: attachments_staged_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX attachments_staged_idx ON openbot.attachments USING btree (created_at) WHERE (attached_at IS NULL);


--
-- Name: attachments_upload_group_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX attachments_upload_group_idx ON openbot.attachments USING btree (channel_id, uploaded_by, upload_group) WHERE (attached_at IS NULL);


--
-- Name: attachments_uploaded_by_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX attachments_uploaded_by_idx ON openbot.attachments USING btree (uploaded_by);


--
-- Name: audit_events_actor_time_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX audit_events_actor_time_idx ON openbot.audit_events USING btree (actor_user_id, created_at DESC NULLS LAST, id DESC NULLS LAST);


--
-- Name: audit_events_created_at_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX audit_events_created_at_idx ON openbot.audit_events USING btree (created_at);


--
-- Name: audit_events_initiator_time_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX audit_events_initiator_time_idx ON openbot.audit_events USING btree (initiator_kind, created_at DESC NULLS LAST, id DESC NULLS LAST);


--
-- Name: audit_events_target_time_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX audit_events_target_time_idx ON openbot.audit_events USING btree (target_type, target_id, created_at DESC NULLS LAST, id DESC NULLS LAST);


--
-- Name: audit_events_type_time_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX audit_events_type_time_idx ON openbot.audit_events USING btree (event_type, created_at DESC NULLS LAST, id DESC NULLS LAST);


--
-- Name: brokered_connections_deployment_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX brokered_connections_deployment_idx ON openbot.brokered_connections USING btree (provider, app) WHERE (holder = 'deployment'::text);


--
-- Name: brokered_connections_person_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX brokered_connections_person_idx ON openbot.brokered_connections USING btree (provider, app, user_id) WHERE (holder = 'person'::text);


--
-- Name: brokered_connections_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX brokered_connections_user_idx ON openbot.brokered_connections USING btree (user_id);


--
-- Name: channels_awaiting_summary_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX channels_awaiting_summary_idx ON openbot.channels USING btree (id) WHERE ((summary IS NULL) AND (deleted_at IS NULL));


--
-- Name: channels_recent_activity_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX channels_recent_activity_idx ON openbot.channels USING btree (COALESCE(last_message_at, created_at) DESC);


--
-- Name: composio_connections_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX composio_connections_user_idx ON openbot.composio_connections USING btree (user_id);


--
-- Name: computer_page_frame_captured_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX computer_page_frame_captured_idx ON openbot.computer_page_frame USING btree (captured_at);


--
-- Name: credentials_active_key_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX credentials_active_key_idx ON openbot.credentials USING btree (kind, provider, key_id) WHERE (revoked_at IS NULL);


--
-- Name: delivery_binding_identity_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX delivery_binding_identity_idx ON openbot.delivery_bindings USING btree (transport, realm, identity);


--
-- Name: delivery_bindings_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX delivery_bindings_owner_idx ON openbot.delivery_bindings USING btree (owner_user_id);


--
-- Name: delivery_inbox_dedupe_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX delivery_inbox_dedupe_idx ON openbot.delivery_inbox USING btree (source, realm, external_id);


--
-- Name: delivery_inbox_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX delivery_inbox_owner_idx ON openbot.delivery_inbox USING btree (owner_user_id, created_at);


--
-- Name: delivery_outbox_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX delivery_outbox_owner_idx ON openbot.delivery_outbox USING btree (owner_user_id, created_at);


--
-- Name: delivery_outbox_provider_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX delivery_outbox_provider_idx ON openbot.delivery_outbox USING btree (transport, provider_id);


--
-- Name: demonstrations_active_bot_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX demonstrations_active_bot_idx ON openbot.demonstrations USING btree (bot_id) WHERE (status = 'recording'::text);


--
-- Name: demonstrations_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX demonstrations_owner_idx ON openbot.demonstrations USING btree (owner_user_id, created_at);


--
-- Name: group_bot_threads_thread_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX group_bot_threads_thread_idx ON openbot.group_bot_threads USING btree (thread_id);


--
-- Name: group_messages_channel_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX group_messages_channel_idx ON openbot.group_messages USING btree (channel_id, created_at, id);


--
-- Name: identity_link_challenges_expiry_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX identity_link_challenges_expiry_idx ON openbot.identity_link_challenges USING btree (expires_at);


--
-- Name: identity_link_challenges_user_provider_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX identity_link_challenges_user_provider_idx ON openbot.identity_link_challenges USING btree (user_id, provider);


--
-- Name: identity_links_credential_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX identity_links_credential_idx ON openbot.identity_links USING btree (credential_id) WHERE (credential_id IS NOT NULL);


--
-- Name: identity_links_identity_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX identity_links_identity_idx ON openbot.identity_links USING btree (provider, realm, subject);


--
-- Name: identity_links_user_realm_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX identity_links_user_realm_idx ON openbot.identity_links USING btree (user_id, provider, realm);


--
-- Name: intelligence_channel_mappings_thread_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX intelligence_channel_mappings_thread_idx ON openbot.intelligence_channel_mappings USING btree (thread_id);


--
-- Name: mcp_user_credentials_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX mcp_user_credentials_user_idx ON openbot.mcp_user_credentials USING btree (user_id);


--
-- Name: memory_sources_due_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX memory_sources_due_idx ON openbot.memory_sources USING btree (enabled, next_sync_at);


--
-- Name: memory_sources_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX memory_sources_owner_idx ON openbot.memory_sources USING btree (owner_user_id);


--
-- Name: model_usage_created_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX model_usage_created_idx ON openbot.model_usage USING btree (created_at);


--
-- Name: model_usage_model_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX model_usage_model_idx ON openbot.model_usage USING btree (model, created_at);


--
-- Name: pending_authorizations_server_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX pending_authorizations_server_idx ON openbot.pending_authorizations USING btree (server_id);


--
-- Name: personal_memories_formed_digest_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX personal_memories_formed_digest_idx ON openbot.personal_memories USING btree (owner_user_id, import_digest) WHERE (formed_by = 'bot'::text);


--
-- Name: personal_memories_formed_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX personal_memories_formed_idx ON openbot.personal_memories USING btree (owner_user_id, formed_by_agent_id);


--
-- Name: personal_memories_import_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX personal_memories_import_idx ON openbot.personal_memories USING btree (source_id, external_id);


--
-- Name: personal_memories_intelligence_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX personal_memories_intelligence_idx ON openbot.personal_memories USING btree (owner_user_id, intelligence_memory_id);


--
-- Name: personal_memories_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX personal_memories_owner_idx ON openbot.personal_memories USING btree (owner_user_id, enabled);


--
-- Name: plugin_grants_agent_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX plugin_grants_agent_idx ON openbot.plugin_grants USING btree (agent_id);


--
-- Name: proactive_settings_due_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX proactive_settings_due_idx ON openbot.proactive_settings USING btree (enabled, next_run_at);


--
-- Name: proactive_settings_owner_agent_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX proactive_settings_owner_agent_idx ON openbot.proactive_settings USING btree (owner_user_id, agent_id);


--
-- Name: proactive_suggestions_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX proactive_suggestions_owner_idx ON openbot.proactive_suggestions USING btree (owner_user_id, status, created_at);


--
-- Name: proactive_suggestions_run_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX proactive_suggestions_run_idx ON openbot.proactive_suggestions USING btree (run_id);


--
-- Name: push_devices_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX push_devices_owner_idx ON openbot.push_devices USING btree (owner_user_id);


--
-- Name: responsibilities_owner_status_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibilities_owner_status_idx ON openbot.responsibilities USING btree (owner_user_id, status);


--
-- Name: responsibility_events_source_id_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX responsibility_events_source_id_idx ON openbot.responsibility_events USING btree (owner_user_id, source, external_id);


--
-- Name: responsibility_runs_event_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX responsibility_runs_event_idx ON openbot.responsibility_runs USING btree (responsibility_id, event_id);


--
-- Name: responsibility_runs_status_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibility_runs_status_idx ON openbot.responsibility_runs USING btree (status, created_at);


--
-- Name: responsibility_source_bindings_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibility_source_bindings_owner_idx ON openbot.responsibility_source_bindings USING btree (owner_user_id);


--
-- Name: responsibility_triggers_kind_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibility_triggers_kind_idx ON openbot.responsibility_triggers USING btree (kind);


--
-- Name: responsibility_triggers_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibility_triggers_owner_idx ON openbot.responsibility_triggers USING btree (owner_user_id);


--
-- Name: responsibility_triggers_responsibility_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX responsibility_triggers_responsibility_idx ON openbot.responsibility_triggers USING btree (responsibility_id);


--
-- Name: routine_runs_by_routine_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX routine_runs_by_routine_idx ON openbot.routine_runs USING btree (routine_id, started_at);


--
-- Name: routines_by_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX routines_by_owner_idx ON openbot.routines USING btree (owner_user_id, enabled);


--
-- Name: routines_due_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX routines_due_idx ON openbot.routines USING btree (enabled, next_run_at);


--
-- Name: saved_logins_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX saved_logins_owner_idx ON openbot.saved_logins USING btree (owner_user_id);


--
-- Name: saved_logins_owner_origin_username_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX saved_logins_owner_origin_username_idx ON openbot.saved_logins USING btree (owner_user_id, origin, username);


--
-- Name: scim_connection_bindings_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_connection_bindings_connection_idx ON openbot.scim_connection_bindings USING btree (connection_id);


--
-- Name: scim_group_members_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_group_members_connection_idx ON openbot.scim_group_members USING btree (connection_id);


--
-- Name: scim_group_members_group_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_group_members_group_idx ON openbot.scim_group_members USING btree (group_id);


--
-- Name: scim_group_members_scim_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_group_members_scim_user_idx ON openbot.scim_group_members USING btree (scim_user_id);


--
-- Name: scim_groups_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_groups_connection_idx ON openbot.scim_groups USING btree (connection_id);


--
-- Name: scim_groups_domain_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_groups_domain_idx ON openbot.scim_groups USING btree (provisioning_domain_id);


--
-- Name: scim_identity_tombstones_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_identity_tombstones_connection_idx ON openbot.scim_identity_tombstones USING btree (connection_id);


--
-- Name: scim_identity_tombstones_domain_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_identity_tombstones_domain_idx ON openbot.scim_identity_tombstones USING btree (provisioning_domain_id);


--
-- Name: scim_identity_tombstones_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_identity_tombstones_user_idx ON openbot.scim_identity_tombstones USING btree (user_id);


--
-- Name: scim_projection_grants_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_projection_grants_connection_idx ON openbot.scim_projection_grants USING btree (connection_id);


--
-- Name: scim_projection_grants_domain_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_projection_grants_domain_idx ON openbot.scim_projection_grants USING btree (provisioning_domain_id);


--
-- Name: scim_projection_grants_scim_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_projection_grants_scim_user_idx ON openbot.scim_projection_grants USING btree (scim_user_id);


--
-- Name: scim_projection_grants_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_projection_grants_user_idx ON openbot.scim_projection_grants USING btree (user_id);


--
-- Name: scim_subjects_profile_source_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_subjects_profile_source_idx ON openbot.scim_subjects USING btree (profile_source_id);


--
-- Name: scim_users_connection_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_users_connection_idx ON openbot.scim_users USING btree (connection_id);


--
-- Name: scim_users_domain_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_users_domain_idx ON openbot.scim_users USING btree (provisioning_domain_id);


--
-- Name: scim_users_user_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX scim_users_user_idx ON openbot.scim_users USING btree (user_id);


--
-- Name: shared_use_requests_pending_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX shared_use_requests_pending_idx ON openbot.shared_use_requests USING btree (agent_id, server_id) WHERE (status = 'pending'::text);


--
-- Name: shared_use_requests_status_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX shared_use_requests_status_idx ON openbot.shared_use_requests USING btree (status);


--
-- Name: sign_in_requests_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX sign_in_requests_owner_idx ON openbot.sign_in_requests USING btree (owner_user_id, status);


--
-- Name: skill_tools_ref_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX skill_tools_ref_idx ON openbot.skill_tools USING btree (ref);


--
-- Name: skills_owner_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX skills_owner_idx ON openbot.skills USING btree (owner_user_id);


--
-- Name: skills_slug_key; Type: INDEX; Schema: openbot; Owner: -
--

CREATE UNIQUE INDEX skills_slug_key ON openbot.skills USING btree (slug);


--
-- Name: voice_sessions_channel_started_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX voice_sessions_channel_started_idx ON openbot.voice_sessions USING btree (channel_id, started_at, id);


--
-- Name: work_items_claimable_idx; Type: INDEX; Schema: openbot; Owner: -
--

CREATE INDEX work_items_claimable_idx ON openbot.work_items USING btree (kind, run_at);


--
-- Name: audit_events audit_events_append_only; Type: TRIGGER; Schema: openbot; Owner: -
--

CREATE TRIGGER audit_events_append_only BEFORE DELETE OR UPDATE ON openbot.audit_events FOR EACH ROW EXECUTE FUNCTION openbot.prevent_audit_event_mutation();


--
-- Name: audit_events audit_events_no_truncate; Type: TRIGGER; Schema: openbot; Owner: -
--

CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON openbot.audit_events FOR EACH STATEMENT EXECUTE FUNCTION openbot.prevent_audit_event_mutation();


--
-- Name: accounts accounts_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.accounts
    ADD CONSTRAINT accounts_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: agent_preferences agent_preferences_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_preferences
    ADD CONSTRAINT agent_preferences_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: agent_preferences agent_preferences_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_preferences
    ADD CONSTRAINT agent_preferences_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: agent_profiles agent_profiles_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_profiles
    ADD CONSTRAINT agent_profiles_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: agent_profiles agent_profiles_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agent_profiles
    ADD CONSTRAINT agent_profiles_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE SET NULL;


--
-- Name: agents agents_package_id_deployment_packages_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.agents
    ADD CONSTRAINT agents_package_id_deployment_packages_id_fk FOREIGN KEY (package_id) REFERENCES openbot.deployment_packages(id) ON DELETE SET NULL;


--
-- Name: app_access_requests app_access_requests_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.app_access_requests
    ADD CONSTRAINT app_access_requests_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: app_access_requests app_access_requests_requested_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.app_access_requests
    ADD CONSTRAINT app_access_requests_requested_by_users_id_fk FOREIGN KEY (requested_by) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: approval_preferences approval_preferences_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_preferences
    ADD CONSTRAINT approval_preferences_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: approval_requests approval_requests_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_requests
    ADD CONSTRAINT approval_requests_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: approval_rules approval_rules_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_rules
    ADD CONSTRAINT approval_rules_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: approval_team_rules approval_team_rules_created_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_team_rules
    ADD CONSTRAINT approval_team_rules_created_by_users_id_fk FOREIGN KEY (created_by) REFERENCES openbot.users(id) ON DELETE SET NULL;


--
-- Name: approval_team_settings approval_team_settings_updated_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.approval_team_settings
    ADD CONSTRAINT approval_team_settings_updated_by_users_id_fk FOREIGN KEY (updated_by) REFERENCES openbot.users(id) ON DELETE SET NULL;


--
-- Name: attachments attachments_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.attachments
    ADD CONSTRAINT attachments_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: attachments attachments_uploaded_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.attachments
    ADD CONSTRAINT attachments_uploaded_by_users_id_fk FOREIGN KEY (uploaded_by) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: bot_lifecycle bot_lifecycle_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.bot_lifecycle
    ADD CONSTRAINT bot_lifecycle_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: bot_lifecycle bot_lifecycle_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.bot_lifecycle
    ADD CONSTRAINT bot_lifecycle_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: channel_agents channel_agents_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_agents
    ADD CONSTRAINT channel_agents_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: channel_agents channel_agents_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_agents
    ADD CONSTRAINT channel_agents_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: channel_memberships channel_memberships_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_memberships
    ADD CONSTRAINT channel_memberships_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: channel_memberships channel_memberships_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channel_memberships
    ADD CONSTRAINT channel_memberships_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: channels channels_last_message_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channels
    ADD CONSTRAINT channels_last_message_agent_id_agents_id_fk FOREIGN KEY (last_message_agent_id) REFERENCES openbot.agents(id) ON DELETE SET NULL;


--
-- Name: channels channels_package_id_deployment_packages_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.channels
    ADD CONSTRAINT channels_package_id_deployment_packages_id_fk FOREIGN KEY (package_id) REFERENCES openbot.deployment_packages(id) ON DELETE SET NULL;


--
-- Name: component_exclusions component_exclusions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.component_exclusions
    ADD CONSTRAINT component_exclusions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: component_exclusions component_exclusions_component_name_components_name_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.component_exclusions
    ADD CONSTRAINT component_exclusions_component_name_components_name_fk FOREIGN KEY (component_name) REFERENCES openbot.components(name) ON DELETE CASCADE;


--
-- Name: component_functions component_functions_component_name_components_name_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.component_functions
    ADD CONSTRAINT component_functions_component_name_components_name_fk FOREIGN KEY (component_name) REFERENCES openbot.components(name) ON DELETE CASCADE;


--
-- Name: default_opt_outs default_opt_outs_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.default_opt_outs
    ADD CONSTRAINT default_opt_outs_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: default_opt_outs default_opt_outs_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.default_opt_outs
    ADD CONSTRAINT default_opt_outs_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: delivery_bindings delivery_bindings_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_bindings
    ADD CONSTRAINT delivery_bindings_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: delivery_bindings delivery_bindings_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_bindings
    ADD CONSTRAINT delivery_bindings_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: delivery_bindings delivery_bindings_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_bindings
    ADD CONSTRAINT delivery_bindings_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: delivery_challenges delivery_challenges_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_challenges
    ADD CONSTRAINT delivery_challenges_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: delivery_challenges delivery_challenges_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_challenges
    ADD CONSTRAINT delivery_challenges_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: delivery_challenges delivery_challenges_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_challenges
    ADD CONSTRAINT delivery_challenges_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: delivery_inbox delivery_inbox_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_inbox
    ADD CONSTRAINT delivery_inbox_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: delivery_inbox delivery_inbox_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_inbox
    ADD CONSTRAINT delivery_inbox_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: delivery_inbox delivery_inbox_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_inbox
    ADD CONSTRAINT delivery_inbox_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: delivery_outbox delivery_outbox_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_outbox
    ADD CONSTRAINT delivery_outbox_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: delivery_outbox delivery_outbox_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_outbox
    ADD CONSTRAINT delivery_outbox_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: delivery_outbox delivery_outbox_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.delivery_outbox
    ADD CONSTRAINT delivery_outbox_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: demonstrations demonstrations_bot_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.demonstrations
    ADD CONSTRAINT demonstrations_bot_id_agents_id_fk FOREIGN KEY (bot_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: demonstrations demonstrations_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.demonstrations
    ADD CONSTRAINT demonstrations_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: group_bot_threads group_bot_threads_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_bot_threads
    ADD CONSTRAINT group_bot_threads_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: group_bot_threads group_bot_threads_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_bot_threads
    ADD CONSTRAINT group_bot_threads_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: group_messages group_messages_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_messages
    ADD CONSTRAINT group_messages_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: group_messages group_messages_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.group_messages
    ADD CONSTRAINT group_messages_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: identity_links identity_links_credential_id_credentials_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.identity_links
    ADD CONSTRAINT identity_links_credential_id_credentials_id_fk FOREIGN KEY (credential_id) REFERENCES openbot.credentials(id);


--
-- Name: intelligence_channel_mappings intelligence_channel_mappings_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.intelligence_channel_mappings
    ADD CONSTRAINT intelligence_channel_mappings_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: intelligence_channel_mappings intelligence_channel_mappings_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.intelligence_channel_mappings
    ADD CONSTRAINT intelligence_channel_mappings_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: mcp_servers mcp_servers_credential_id_credentials_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_servers
    ADD CONSTRAINT mcp_servers_credential_id_credentials_id_fk FOREIGN KEY (credential_id) REFERENCES openbot.credentials(id) ON DELETE RESTRICT;


--
-- Name: mcp_tools mcp_tools_server_id_mcp_servers_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_tools
    ADD CONSTRAINT mcp_tools_server_id_mcp_servers_id_fk FOREIGN KEY (server_id) REFERENCES openbot.mcp_servers(id) ON DELETE CASCADE;


--
-- Name: mcp_user_credentials mcp_user_credentials_credential_id_credentials_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_user_credentials
    ADD CONSTRAINT mcp_user_credentials_credential_id_credentials_id_fk FOREIGN KEY (credential_id) REFERENCES openbot.credentials(id);


--
-- Name: mcp_user_credentials mcp_user_credentials_server_id_mcp_servers_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_user_credentials
    ADD CONSTRAINT mcp_user_credentials_server_id_mcp_servers_id_fk FOREIGN KEY (server_id) REFERENCES openbot.mcp_servers(id) ON DELETE CASCADE;


--
-- Name: mcp_user_credentials mcp_user_credentials_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.mcp_user_credentials
    ADD CONSTRAINT mcp_user_credentials_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: memory_sources memory_sources_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.memory_sources
    ADD CONSTRAINT memory_sources_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: memory_sources memory_sources_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.memory_sources
    ADD CONSTRAINT memory_sources_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: pending_authorizations pending_authorizations_actor_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.pending_authorizations
    ADD CONSTRAINT pending_authorizations_actor_id_users_id_fk FOREIGN KEY (actor_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: pending_authorizations pending_authorizations_server_id_mcp_servers_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.pending_authorizations
    ADD CONSTRAINT pending_authorizations_server_id_mcp_servers_id_fk FOREIGN KEY (server_id) REFERENCES openbot.mcp_servers(id) ON DELETE CASCADE;


--
-- Name: personal_memories personal_memories_formed_by_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.personal_memories
    ADD CONSTRAINT personal_memories_formed_by_agent_id_agents_id_fk FOREIGN KEY (formed_by_agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: personal_memories personal_memories_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.personal_memories
    ADD CONSTRAINT personal_memories_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: personal_memories personal_memories_source_id_memory_sources_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.personal_memories
    ADD CONSTRAINT personal_memories_source_id_memory_sources_id_fk FOREIGN KEY (source_id) REFERENCES openbot.memory_sources(id) ON DELETE CASCADE;


--
-- Name: plugin_grants plugin_grants_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.plugin_grants
    ADD CONSTRAINT plugin_grants_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: proactive_settings proactive_settings_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_settings
    ADD CONSTRAINT proactive_settings_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: proactive_settings proactive_settings_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_settings
    ADD CONSTRAINT proactive_settings_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: proactive_suggestions proactive_suggestions_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_suggestions
    ADD CONSTRAINT proactive_suggestions_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: proactive_suggestions proactive_suggestions_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_suggestions
    ADD CONSTRAINT proactive_suggestions_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: proactive_suggestions proactive_suggestions_setting_id_proactive_settings_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.proactive_suggestions
    ADD CONSTRAINT proactive_suggestions_setting_id_proactive_settings_id_fk FOREIGN KEY (setting_id) REFERENCES openbot.proactive_settings(id) ON DELETE CASCADE;


--
-- Name: push_devices push_devices_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.push_devices
    ADD CONSTRAINT push_devices_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: responsibilities responsibilities_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibilities
    ADD CONSTRAINT responsibilities_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: responsibilities responsibilities_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibilities
    ADD CONSTRAINT responsibilities_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: responsibility_events responsibility_events_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_events
    ADD CONSTRAINT responsibility_events_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: responsibility_runs responsibility_runs_event_id_responsibility_events_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_runs
    ADD CONSTRAINT responsibility_runs_event_id_responsibility_events_id_fk FOREIGN KEY (event_id) REFERENCES openbot.responsibility_events(id) ON DELETE CASCADE;


--
-- Name: responsibility_runs responsibility_runs_responsibility_id_responsibilities_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_runs
    ADD CONSTRAINT responsibility_runs_responsibility_id_responsibilities_id_fk FOREIGN KEY (responsibility_id) REFERENCES openbot.responsibilities(id) ON DELETE CASCADE;


--
-- Name: responsibility_source_bindings responsibility_source_bindings_credential_id_credentials_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_source_bindings
    ADD CONSTRAINT responsibility_source_bindings_credential_id_credentials_id_fk FOREIGN KEY (credential_id) REFERENCES openbot.credentials(id);


--
-- Name: responsibility_source_bindings responsibility_source_bindings_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_source_bindings
    ADD CONSTRAINT responsibility_source_bindings_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: responsibility_triggers responsibility_triggers_credential_id_credentials_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_triggers
    ADD CONSTRAINT responsibility_triggers_credential_id_credentials_id_fk FOREIGN KEY (credential_id) REFERENCES openbot.credentials(id);


--
-- Name: responsibility_triggers responsibility_triggers_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_triggers
    ADD CONSTRAINT responsibility_triggers_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: responsibility_triggers responsibility_triggers_responsibility_id_responsibilities_id_f; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.responsibility_triggers
    ADD CONSTRAINT responsibility_triggers_responsibility_id_responsibilities_id_f FOREIGN KEY (responsibility_id) REFERENCES openbot.responsibilities(id) ON DELETE CASCADE;


--
-- Name: routine_runs routine_runs_routine_id_routines_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routine_runs
    ADD CONSTRAINT routine_runs_routine_id_routines_id_fk FOREIGN KEY (routine_id) REFERENCES openbot.routines(id) ON DELETE CASCADE;


--
-- Name: routines routines_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routines
    ADD CONSTRAINT routines_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: routines routines_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.routines
    ADD CONSTRAINT routines_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: saved_logins saved_logins_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.saved_logins
    ADD CONSTRAINT saved_logins_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: scim_group_members scim_group_members_group_id_scim_groups_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_group_members
    ADD CONSTRAINT scim_group_members_group_id_scim_groups_id_fk FOREIGN KEY (group_id) REFERENCES openbot.scim_groups(id) ON DELETE CASCADE;


--
-- Name: scim_group_members scim_group_members_scim_user_id_scim_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_group_members
    ADD CONSTRAINT scim_group_members_scim_user_id_scim_users_id_fk FOREIGN KEY (scim_user_id) REFERENCES openbot.scim_users(id) ON DELETE CASCADE;


--
-- Name: scim_identity_tombstones scim_identity_tombstones_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_identity_tombstones
    ADD CONSTRAINT scim_identity_tombstones_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: scim_projection_grants scim_projection_grants_scim_user_id_scim_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_projection_grants
    ADD CONSTRAINT scim_projection_grants_scim_user_id_scim_users_id_fk FOREIGN KEY (scim_user_id) REFERENCES openbot.scim_users(id) ON DELETE CASCADE;


--
-- Name: scim_projection_grants scim_projection_grants_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_projection_grants
    ADD CONSTRAINT scim_projection_grants_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: scim_subjects scim_subjects_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_subjects
    ADD CONSTRAINT scim_subjects_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: scim_users scim_users_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.scim_users
    ADD CONSTRAINT scim_users_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: sessions sessions_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sessions
    ADD CONSTRAINT sessions_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: shared_use_approval_members shared_use_approval_members_approval_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_approval_members
    ADD CONSTRAINT shared_use_approval_members_approval_fk FOREIGN KEY (agent_id, server_id) REFERENCES openbot.shared_use_approvals(agent_id, server_id) ON DELETE CASCADE;


--
-- Name: shared_use_approvals shared_use_approvals_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_approvals
    ADD CONSTRAINT shared_use_approvals_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: shared_use_approvals shared_use_approvals_server_id_mcp_servers_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_approvals
    ADD CONSTRAINT shared_use_approvals_server_id_mcp_servers_id_fk FOREIGN KEY (server_id) REFERENCES openbot.mcp_servers(id) ON DELETE CASCADE;


--
-- Name: shared_use_requests shared_use_requests_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_requests
    ADD CONSTRAINT shared_use_requests_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: shared_use_requests shared_use_requests_server_id_mcp_servers_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.shared_use_requests
    ADD CONSTRAINT shared_use_requests_server_id_mcp_servers_id_fk FOREIGN KEY (server_id) REFERENCES openbot.mcp_servers(id) ON DELETE CASCADE;


--
-- Name: sign_in_requests sign_in_requests_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sign_in_requests
    ADD CONSTRAINT sign_in_requests_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: skill_tools skill_tools_skill_id_skills_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.skill_tools
    ADD CONSTRAINT skill_tools_skill_id_skills_id_fk FOREIGN KEY (skill_id) REFERENCES openbot.skills(id) ON DELETE CASCADE;


--
-- Name: skills skills_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.skills
    ADD CONSTRAINT skills_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: sso_providers sso_providers_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.sso_providers
    ADD CONSTRAINT sso_providers_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE SET NULL;


--
-- Name: team_bot_assignments team_bot_assignments_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_assignments
    ADD CONSTRAINT team_bot_assignments_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: team_bot_assignments team_bot_assignments_assigned_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_assignments
    ADD CONSTRAINT team_bot_assignments_assigned_by_users_id_fk FOREIGN KEY (assigned_by) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: team_bot_audience team_bot_audience_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_audience
    ADD CONSTRAINT team_bot_audience_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: team_bot_consent_defaults team_bot_consent_defaults_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_consent_defaults
    ADD CONSTRAINT team_bot_consent_defaults_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: team_bot_consents team_bot_consents_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_consents
    ADD CONSTRAINT team_bot_consents_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: team_bot_consents team_bot_consents_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_consents
    ADD CONSTRAINT team_bot_consents_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: team_bot_publications team_bot_publications_agent_id_agents_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_publications
    ADD CONSTRAINT team_bot_publications_agent_id_agents_id_fk FOREIGN KEY (agent_id) REFERENCES openbot.agents(id) ON DELETE CASCADE;


--
-- Name: team_bot_publications team_bot_publications_published_by_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.team_bot_publications
    ADD CONSTRAINT team_bot_publications_published_by_users_id_fk FOREIGN KEY (published_by) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: update_routing_preferences update_routing_preferences_owner_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.update_routing_preferences
    ADD CONSTRAINT update_routing_preferences_owner_user_id_users_id_fk FOREIGN KEY (owner_user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: user_instructions user_instructions_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.user_instructions
    ADD CONSTRAINT user_instructions_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.user_roles
    ADD CONSTRAINT user_roles_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: voice_sessions voice_sessions_channel_id_channels_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.voice_sessions
    ADD CONSTRAINT voice_sessions_channel_id_channels_id_fk FOREIGN KEY (channel_id) REFERENCES openbot.channels(id) ON DELETE CASCADE;


--
-- Name: voice_sessions voice_sessions_user_id_users_id_fk; Type: FK CONSTRAINT; Schema: openbot; Owner: -
--

ALTER TABLE ONLY openbot.voice_sessions
    ADD CONSTRAINT voice_sessions_user_id_users_id_fk FOREIGN KEY (user_id) REFERENCES openbot.users(id) ON DELETE CASCADE;


--
-- Name: __drizzle_migrations; Type: ROW SECURITY; Schema: drizzle; Owner: -
--

ALTER TABLE drizzle.__drizzle_migrations ENABLE ROW LEVEL SECURITY;

--
-- Name: threads; Type: ROW SECURITY; Schema: jevie_runtime; Owner: -
--

ALTER TABLE jevie_runtime.threads ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: action_policy; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.action_policy ENABLE ROW LEVEL SECURITY;

--
-- Name: action_records; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.action_records ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_preferences; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.agent_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: agent_profiles; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.agent_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: agents; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.agents ENABLE ROW LEVEL SECURITY;

--
-- Name: app_access_requests; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.app_access_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_preferences; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.approval_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_requests; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.approval_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_rules; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.approval_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_team_rules; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.approval_team_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: approval_team_settings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.approval_team_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: attachments; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: bot_lifecycle; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.bot_lifecycle ENABLE ROW LEVEL SECURITY;

--
-- Name: brokered_connections; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.brokered_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: capability_settings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.capability_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: channel_agents; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.channel_agents ENABLE ROW LEVEL SECURITY;

--
-- Name: channel_memberships; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.channel_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: channels; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.channels ENABLE ROW LEVEL SECURITY;

--
-- Name: component_exclusions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.component_exclusions ENABLE ROW LEVEL SECURITY;

--
-- Name: component_functions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.component_functions ENABLE ROW LEVEL SECURITY;

--
-- Name: components; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.components ENABLE ROW LEVEL SECURITY;

--
-- Name: composio_connections; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.composio_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: computer_page_frame; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.computer_page_frame ENABLE ROW LEVEL SECURITY;

--
-- Name: computer_snapshot; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.computer_snapshot ENABLE ROW LEVEL SECURITY;

--
-- Name: credentials; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: default_opt_outs; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.default_opt_outs ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_bindings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.delivery_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_challenges; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.delivery_challenges ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_inbox; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.delivery_inbox ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_outbox; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.delivery_outbox ENABLE ROW LEVEL SECURITY;

--
-- Name: demonstrations; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.demonstrations ENABLE ROW LEVEL SECURITY;

--
-- Name: deployment_packages; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.deployment_packages ENABLE ROW LEVEL SECURITY;

--
-- Name: enterprise_settings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.enterprise_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: group_bot_threads; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.group_bot_threads ENABLE ROW LEVEL SECURITY;

--
-- Name: group_messages; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.group_messages ENABLE ROW LEVEL SECURITY;

--
-- Name: identity_link_challenges; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.identity_link_challenges ENABLE ROW LEVEL SECURITY;

--
-- Name: identity_links; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.identity_links ENABLE ROW LEVEL SECURITY;

--
-- Name: intelligence_channel_mappings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.intelligence_channel_mappings ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_settings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.learning_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_thread_bindings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.learning_thread_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_servers; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.mcp_servers ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_tools; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.mcp_tools ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_user_credentials; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.mcp_user_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_sources; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.memory_sources ENABLE ROW LEVEL SECURITY;

--
-- Name: model_usage; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.model_usage ENABLE ROW LEVEL SECURITY;

--
-- Name: network_policies; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.network_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: pending_authorizations; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.pending_authorizations ENABLE ROW LEVEL SECURITY;

--
-- Name: personal_memories; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.personal_memories ENABLE ROW LEVEL SECURITY;

--
-- Name: plugin_grants; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.plugin_grants ENABLE ROW LEVEL SECURITY;

--
-- Name: proactive_settings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.proactive_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: proactive_suggestions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.proactive_suggestions ENABLE ROW LEVEL SECURITY;

--
-- Name: push_devices; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.push_devices ENABLE ROW LEVEL SECURITY;

--
-- Name: responsibilities; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.responsibilities ENABLE ROW LEVEL SECURITY;

--
-- Name: responsibility_events; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.responsibility_events ENABLE ROW LEVEL SECURITY;

--
-- Name: responsibility_runs; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.responsibility_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: responsibility_source_bindings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.responsibility_source_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: responsibility_triggers; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.responsibility_triggers ENABLE ROW LEVEL SECURITY;

--
-- Name: revoked_access; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.revoked_access ENABLE ROW LEVEL SECURITY;

--
-- Name: routine_runs; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.routine_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: routine_sweeps; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.routine_sweeps ENABLE ROW LEVEL SECURITY;

--
-- Name: routines; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.routines ENABLE ROW LEVEL SECURITY;

--
-- Name: sandboxed_components; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.sandboxed_components ENABLE ROW LEVEL SECURITY;

--
-- Name: saved_logins; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.saved_logins ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_connection_bindings; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_connection_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_group_members; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_group_members ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_groups; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_identity_tombstones; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_identity_tombstones ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_projection_grants; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_projection_grants ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_subjects; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_subjects ENABLE ROW LEVEL SECURITY;

--
-- Name: scim_users; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.scim_users ENABLE ROW LEVEL SECURITY;

--
-- Name: sessions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: shared_use_approval_members; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.shared_use_approval_members ENABLE ROW LEVEL SECURITY;

--
-- Name: shared_use_approvals; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.shared_use_approvals ENABLE ROW LEVEL SECURITY;

--
-- Name: shared_use_requests; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.shared_use_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: sign_in_requests; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.sign_in_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: skill_tools; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.skill_tools ENABLE ROW LEVEL SECURITY;

--
-- Name: skills; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.skills ENABLE ROW LEVEL SECURITY;

--
-- Name: sso_providers; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.sso_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: team_bot_assignments; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.team_bot_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: team_bot_audience; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.team_bot_audience ENABLE ROW LEVEL SECURITY;

--
-- Name: team_bot_consent_defaults; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.team_bot_consent_defaults ENABLE ROW LEVEL SECURITY;

--
-- Name: team_bot_consents; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.team_bot_consents ENABLE ROW LEVEL SECURITY;

--
-- Name: team_bot_publications; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.team_bot_publications ENABLE ROW LEVEL SECURITY;

--
-- Name: update_routing_preferences; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.update_routing_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: user_instructions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.user_instructions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_roles; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.user_roles ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.users ENABLE ROW LEVEL SECURITY;

--
-- Name: verifications; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.verifications ENABLE ROW LEVEL SECURITY;

--
-- Name: voice_sessions; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.voice_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: work_items; Type: ROW SECURITY; Schema: openbot; Owner: -
--

ALTER TABLE openbot.work_items ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--



REVOKE ALL ON SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA openbot,jevie_runtime,drizzle FROM PUBLIC;
DO $$ DECLARE r text; BEGIN
 FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN
   EXECUTE format('REVOKE ALL ON SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
   EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
   EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA openbot,jevie_runtime,drizzle FROM %I',r);
  END IF;
 END LOOP;
END $$;
