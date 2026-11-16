"""Exporta a memoria validada do radar para JSON privado do Accounts Hub.

Nao acessa rede, nao extrai mensagens e nao modifica estado/config/execucao.
A versao das configuracoes remotas e obrigatoria. Saida real fica apenas em
outputs/whatsapp-radar-clientes/crm/, fora da arvore publicavel.
"""
from __future__ import annotations

import argparse
from collections import Counter
from copy import deepcopy
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys

WORKSPACE = Path(__file__).resolve().parents[2]
RADAR_ROOT = WORKSPACE / "outputs" / "whatsapp-radar-clientes"
PRIVATE_OUTPUT_ROOT = RADAR_ROOT / "crm"
MAX_BYTES = 2 * 1024 * 1024
BRT = timezone(timedelta(hours=-3), "BRT")
ITEM_STATUSES = {"aberta", "em_andamento", "aguardando_cliente", "aguardando_equipe",
                 "aguardando_direcao", "concluida", "cancelada"}
CASE_STATUSES = {"open", "corrected", "not_assessable"}
CASE_TYPES = {"sem_resposta_observada", "resposta_parcial", "resposta_vaga",
              "contradicao", "duvida_factual", "tom_desalinhado"}
LOCAL_PATH = re.compile(r"(?:[A-Za-z]:[\\/]|file://|/(?:Users|home|mnt)/)")
ITEM_FIELDS = set("""
item_id client_id group_ids group_id group_title kind kind_original summary status client_account_display
owner_display owner_person_ids owner_basis owner_team owner_scope waiting_on
due_at due_text due_precision due_basis first_seen_at last_evidence_at last_reviewed_at
evidence_ids acknowledgement_evidence_ids response_evidence_ids completion_evidence_ids
cancellation_evidence_ids uncertainties priority_assessment suggested_next_step
appointment_status approval_window blocking_dependency commitment_history completed_at
completed_by_observed completed_on completion_reported_at completion_reported_by
coordination_context coverage_end_date date_resolution_basis deadline_assessment
deadline_status dependency_type directed_to expected_product_arrival expected_window
meeting_at meeting_status occurrences overdue_assessment plan_parameters planned_action_date
planning_window proposal proposed_meeting_at proposed_meeting_basis proposed_meeting_status
recurrence_as_promised reported_deadline requested_meeting_basis requested_meeting_date
response_evidence_ids sample_availability_expected_date scheduled_meeting_at subchecks subitems
requested_at requested_precision requested_text requester_display request_evidence_ids
delivery_commitments current_commitment_id
""".split())
CASE_FIELDS = set("""
case_id client_id group_id group_title related_item_ids case_type case_subtype subtype
context_summary request_evidence_ids response_evidence_ids response_author_person_id
response_author_display response_author_note other_response_author_person_ids
specific_issue impact_assessment uncertainties suggested_reply suggested_reply_status
needs_confirmation_before_sending status correction_evidence_ids correction_note correction_scope
first_seen_at last_reviewed_at partial_progress_evidence_ids draft_commitment_basis
positive_context elapsed_context status_reason account_role_confirmed
""".split())
EVIDENCE_FIELDS = set("""
evidence_id client_id group_id group_title_at_read group_title author_display message_at
message_date message_date_range message_time_range observed_date_or_range time_precision
summary short_excerpt excerpt_type content_type message_link observed_at
""".split())
PEOPLE_FIELDS = set("person_id display_name role client_id role_evidence team_function identity_scope".split())
EVENT_FIELDS = set("event_id item_id event_type previous_value new_value evidence_ids recorded_at recorded_at_basis".split())
NESTED_FIELDS = set("""
evidence_id evidence_ids related_evidence_id person_id author author_display type reason
message_at message_date message_time_range duration status basis interpretation level
precision start end start_date end_date start_precision start_basis end_basis
first_observed_message last_observed_message last_known_timed_message
last_observed_message_description end_verified_as_of material requested_from_display
date delivery_status check_id client_reference issue uncertainty communicated_by
due_precision promised_date scope creator_invites_per_day product samples_per_month
display_name completion_confirmed summary is_delivery_commitment kind allocation
amount_brl approval_status campaigns period selected_context other_same_title_context
authors_observed latest_message_at latest_message_summary latest_preview_date preview_author
history_not_analyzed future_resume_requirement same_title_conversations_observed read_receipt_limit
start_time end_time timezone action values before after
commitment_id promised_due_at promised_due_precision promised_due_text promised_at
promised_at_precision promised_by_display promised_by_person_id promised_by_role
revision_kind supersedes_commitment_id
""".split())
# Eventos incrementais podem guardar os campos operacionais anteriores/novos.
# A mesma allowlist exclui diagnosticos e caminhos tambem nesses objetos.
NESTED_FIELDS |= ITEM_FIELDS | CASE_FIELDS | EVIDENCE_FIELDS

class ExportError(ValueError):
    """Entrada inconsistente ou destino nao privado."""

def require(condition, message):
    if not condition:
        raise ExportError(message)

def clean(value):
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items() if key in NESTED_FIELDS}
    if isinstance(value, list):
        return [clean(item) for item in value]
    if isinstance(value, str):
        return "[referência local omitida]" if LOCAL_PATH.search(value) else value
    require(value is None or isinstance(value, (int, float, bool)), "Tipo JSON nao suportado")
    return value

def project(row, fields):
    return {key: clean(value) for key, value in row.items() if key in fields}

def parse_time(value, label, optional=False):
    if value is None and optional:
        return None
    require(isinstance(value, str), f"{label}: data ausente")
    try:
        if "T" in value:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            require(parsed.tzinfo is not None, f"{label}: horario sem fuso")
            return parsed
        return date.fromisoformat(value)
    except ValueError as exc:
        raise ExportError(f"{label}: data invalida") from exc

def before_cutoff(value, cutoff, label):
    parsed = parse_time(value, label, optional=True)
    if parsed is None:
        return
    require(cutoff is not None, f"{label}: corte ausente")
    limit = parse_time(cutoff, "analysis_cutoff")
    require(isinstance(limit, datetime), "analysis_cutoff deve conter horario e fuso")
    require(parsed <= (limit if isinstance(parsed, datetime) else limit.date()),
            f"{label}: evidencia posterior ao corte")

def index(rows, key, label):
    require(isinstance(rows, list), f"{label}: lista ausente")
    result = {}
    for row in rows:
        require(isinstance(row, dict), f"{label}: registro invalido")
        identifier = row.get(key)
        require(isinstance(identifier, str) and bool(identifier), f"{label}: falta {key}")
        require(identifier not in result, f"{label}: ID duplicado {identifier}")
        result[identifier] = row
    return result

def item_groups(item):
    groups = item.get("group_ids")
    if groups is None:
        groups = [item["group_id"]] if item.get("group_id") else []
    require(isinstance(groups, list) and groups and all(isinstance(g, str) for g in groups),
            f"{item.get('item_id')}: grupo ausente")
    return groups

def references(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from references(item)
    elif isinstance(value, list):
        for item in value:
            yield from references(item)

def validate_refs(value, evidence, items, people, allowed_groups):
    for key, item in references(value):
        if key.endswith("evidence_ids") or (key in {"role_evidence", "owner_basis"} and isinstance(item, list)):
            require(isinstance(item, list), f"{key}: referencias invalidas")
            refs = item
        elif key in {"evidence_id", "related_evidence_id"} and item is not None:
            refs = [item]
        else:
            refs = []
        for identifier in refs:
            require(identifier in evidence, f"Evidencia inexistente: {identifier}")
            require(evidence[identifier]["group_id"] in allowed_groups,
                    f"Evidencia de outro grupo: {identifier}")
        if key == "related_item_ids":
            require(isinstance(item, list), "related_item_ids invalido")
            for identifier in item:
                require(identifier in items, f"Item inexistente: {identifier}")
                require(set(item_groups(items[identifier])) <= allowed_groups,
                        f"Item relacionado de outro grupo: {identifier}")
        if key in {"owner_person_ids", "other_response_author_person_ids"}:
            require(isinstance(item, list) and all(pid in people for pid in item),
                    f"{key}: pessoa inexistente")
        if key in {"response_author_person_id", "promised_by_person_id", "person_id"} and item is not None:
            require(item in people, f"Pessoa inexistente: {item}")

def validate_explicit_timing(item, cutoff):
    """Valida datas qualificadas pela analise; nunca converte campos legados."""
    def precise(value, precision, label):
        if value is None:
            require(precision is None, f"{label}: precisao sem data")
            return
        parsed = parse_time(value, label)
        expected = "datetime" if isinstance(parsed, datetime) else "date"
        require(precision == expected, f"{label}: precisao divergente ou ausente")

    identifier = item["item_id"]
    precise(item.get("requested_at"), item.get("requested_precision"), f"{identifier} requested_at")
    before_cutoff(item.get("requested_at"), cutoff, f"{identifier} requested_at")
    request_refs = item.get("request_evidence_ids", [])
    require(isinstance(request_refs, list), f"{identifier}: request_evidence_ids invalido")
    if any(item.get(key) is not None for key in ("requested_at", "requested_text", "requester_display")):
        require(bool(request_refs), f"{identifier}: solicitacao do cliente sem evidencia especifica")

    commitments = item.get("delivery_commitments", [])
    by_id = index(commitments, "commitment_id", f"{identifier}.delivery_commitments")
    superseded = set()
    for commitment in commitments:
        cid = commitment["commitment_id"]
        require(commitment.get("revision_kind") in {"original", "revised"},
                f"{cid}: revision_kind invalido")
        require(isinstance(commitment.get("evidence_ids"), list) and commitment["evidence_ids"],
                f"{cid}: promessa sem evidencia especifica")
        require(commitment.get("promised_by_role") in {None, "account", "equipe", "direcao", "desconhecido"},
                f"{cid}: funcao do autor invalida")
        precise(commitment.get("promised_due_at"), commitment.get("promised_due_precision"),
                f"{cid} promised_due_at")
        precise(commitment.get("promised_at"), commitment.get("promised_at_precision"),
                f"{cid} promised_at")
        before_cutoff(commitment.get("promised_at"), cutoff, f"{cid} promised_at")
        previous = commitment.get("supersedes_commitment_id")
        if previous is not None:
            require(commitment["revision_kind"] == "revised" and previous in by_id and previous != cid,
                    f"{cid}: vinculo de revisao invalido")
            superseded.add(previous)
    for cid in by_id:
        seen, cursor = set(), cid
        while cursor is not None:
            require(cursor not in seen, f"{identifier}: ciclo no historico de promessas")
            seen.add(cursor)
            cursor = by_id[cursor].get("supersedes_commitment_id")
    current = item.get("current_commitment_id")
    if current is not None:
        require(current in by_id and current not in superseded,
                f"{identifier}: compromisso vigente ausente ou substituido")

def build_settings(config):
    require(config.get("profile_label") == "SPHYNX", "Perfil diferente de SPHYNX")
    require(config.get("timezone") == "America/Sao_Paulo", "Fuso diferente de America/Sao_Paulo")
    selected = config.get("monitoring_group_ids")
    require(isinstance(selected, list) and selected and all(isinstance(g, str) for g in selected),
            "Selecao explicita ausente")
    require(len(selected) == len(set(selected)), "Grupo duplicado na selecao")
    groups = index(config.get("groups", []), "group_id", "config.groups")
    clients = index(config.get("clients", []), "client_id", "config.clients")
    catalog = []
    for gid in selected:
        require(gid in groups, f"Grupo selecionado ausente: {gid}")
        row = groups[gid]
        cid = row.get("client_id")
        require(cid in clients, f"{gid}: cliente nao mapeado")
        name, title = clients[cid].get("display_name"), row.get("exact_title", row.get("group_title"))
        require(isinstance(name, str) and name and isinstance(title, str) and title,
                f"{gid}: nome ou titulo ausente")
        catalog.append({"group_id": gid, "client_id": cid,
                        "client_name": clean(name), "group_title": clean(title)})
    schedule_time = config.get("schedule", {}).get("local_time", config.get("schedule_time"))
    require(isinstance(schedule_time, str) and re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", schedule_time),
            "Horario confirmado ausente ou invalido")
    notes = config.get("review_notes", "")
    require(isinstance(notes, str), "review_notes deve ser texto")
    return {"schema_version": 1, "profile_label": "SPHYNX", "timezone": "America/Sao_Paulo",
            "schedule_time": schedule_time, "monitoring_group_ids": list(selected),
            "groups": catalog, "review_notes": clean(notes)}

def export_group(source, catalog, cutoff, accessed):
    gid = catalog["group_id"]
    cov = source.get("coverage", source)
    status = cov.get("coverage_status", cov.get("status", "not_accessed"))
    require(status in {"complete_for_requested_text", "partial", "not_accessed"},
            f"{gid}: cobertura invalida")
    intervals = cov.get("examined_intervals", [])
    require(isinstance(intervals, list), f"{gid}: intervalos invalidos")
    for interval in intervals:
        require(isinstance(interval, dict), f"{gid}: intervalo invalido")
        start = interval.get("start", interval.get("start_date"))
        end = interval.get("end")
        require(start is not None and end is not None, f"{gid}: intervalo incompleto")
        a, b = parse_time(start, "inicio"), parse_time(end, "fim")
        require((a <= b) if isinstance(a, datetime) == isinstance(b, datetime)
                else a.isoformat()[:10] <= b.isoformat()[:10], f"{gid}: intervalo invertido")
        before_cutoff(end, cutoff, f"{gid} fim")
    through = cov.get("continuous_text_through", cov.get("continuous_text_through_proposal"))
    before_cutoff(through, cutoff, f"{gid} checkpoint")
    if through and intervals:
        endpoint = max(parse_time(interval["end"], "fim") for interval in intervals)
        checkpoint = parse_time(through, "checkpoint")
        require(isinstance(endpoint, datetime) and isinstance(checkpoint, datetime)
                and checkpoint <= endpoint, f"{gid}: checkpoint alem do intervalo examinado")
    require(status != "complete_for_requested_text" or (through is not None and intervals),
            f"{gid}: cobertura completa sem checkpoint/intervalo")
    pending = cov.get("pending_media", source.get("pending_media", []))
    require(isinstance(pending, list), f"{gid}: pending_media invalido")
    identity = source.get("conversation_identity_condition", source.get("conversation_disambiguation"))
    result = {**catalog, "coverage": {
        "status": status, "requested_interval": clean(cov.get("requested_interval")),
        "examined_intervals": clean(intervals), "continuous_text_through": through,
        "last_checked_at": source.get("last_checked_at"),
        "last_checked_date": source.get("last_checked_date"),
        "analysis_as_of": source.get("analysis_as_of"),
        "read_in_attempt": gid in accessed,
        "gaps": clean(cov.get("gaps", [])), "identity_condition": clean(identity)},
        "pending_media": clean(pending)}
    return result

def build_exports(state, config, execution, *, settings_version, report_date=None, run_id=None):
    require(type(settings_version) is int and settings_version > 0,
            "settings_version deve ser inteiro positivo, confirmado no CRM")
    settings = build_settings(config)
    selected = set(settings["monitoring_group_ids"])
    catalog = {row["group_id"]: row for row in settings["groups"]}
    # Carteira confirmada é distinta do executor observado em cada conversa.
    account_map = config.get("client_accounts", {})
    require(isinstance(account_map, dict), "client_accounts deve ser um mapa por cliente")
    known_clients = {row.get("client_id") for row in config.get("clients", [])}
    for cid, account in account_map.items():
        require(cid in known_clients and isinstance(account, str)
                and 0 < len(account.strip()) <= 200 and not LOCAL_PATH.search(account),
                "Carteira: cliente desconhecido ou account invalido")
    attempt = execution.get("last_attempt", {})
    raw_status = attempt.get("status")
    require(raw_status in {"completed", "partial", "blocked", "interrupted"},
            "Tentativa ainda nao finalizada ou status desconhecido")
    status = "blocked" if raw_status in {"blocked", "interrupted"} else raw_status
    blocked = status == "blocked"
    cutoff = state.get("analysis_as_of", state.get("analysis_cutoff"))
    parsed_cutoff = parse_time(cutoff, "analysis_cutoff", optional=blocked)
    require(parsed_cutoff is None or isinstance(parsed_cutoff, datetime),
            "analysis_cutoff deve conter horario e fuso")
    generated = (attempt.get("finished_at") or attempt.get("started_at")) if blocked else state.get("updated_at")
    require(isinstance(parse_time(generated, "generated_at"), datetime), "generated_at precisa de fuso")
    if not blocked:
        require(state.get("record_type") == "estado_operacional_validado", "Estado ainda nao validado")
        target = attempt.get("requested_interval", {}).get("to",
                    attempt.get("requested_interval", {}).get("end"))
        require(target is None or target == cutoff,
                "Tentativa recente nao corresponde ao corte validado; nao publicar leitura antiga como nova")
    if report_date is None:
        date_source = (attempt.get("started_at") or generated) if blocked else cutoff
        report_date = parse_time(date_source, "report_date").astimezone(BRT).date().isoformat()
    require(isinstance(parse_time(report_date, "report_date"), date) and "T" not in report_date,
            "report_date deve ter somente data")
    require(run_id is None or (isinstance(run_id, str) and re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", run_id)),
            "run_id invalido")
    accessed = set(attempt.get("accessed_group_ids", [])) & selected
    limitations = clean(attempt.get("limitations", []))
    require(isinstance(limitations, list), "limitations invalido")
    out = {"schema_version": 1, "run_id": run_id, "report_date": report_date,
           "generated_at": generated, "analysis_cutoff": cutoff, "status": status,
           "settings_version": settings_version, "summary": {}, "groups": [], "items": [],
           "communication_cases": [], "evidence": [], "people": [], "events": [],
           "limitations": limitations,
           "attempt": {"status": raw_status, "started_at": attempt.get("started_at"),
                       "finished_at": attempt.get("finished_at"),
                       "requested_group_ids": list(settings["monitoring_group_ids"]),
                       "accessed_group_ids": [] if blocked else sorted(accessed)}}
    if blocked:
        out["limitations"].append(
            "Tentativa sem nova leitura validada; corte anterior preservado, sem alterar checkpoints.")
    else:
        source_groups = index(state.get("groups", []), "group_id", "state.groups")
        for gid in settings["monitoring_group_ids"]:
            source = source_groups.get(gid, {})
            if source:
                require(source.get("client_id") == catalog[gid]["client_id"], f"{gid}: cliente divergente")
                require(source.get("exact_title", source.get("group_title")) == catalog[gid]["group_title"],
                        f"{gid}: titulo divergente")
            group = export_group(source, catalog[gid], cutoff, accessed)
            if account_map.get(group.get("client_id")):
                group["client_account_display"] = account_map[group["client_id"]].strip()
            out["groups"].append(group)
        source_items = index(state.get("items", []), "item_id", "items")
        for row in source_items.values():
            gids = set(item_groups(row))
            if not (gids & selected):
                continue
            require(gids <= selected, f"{row['item_id']}: item mistura grupos dentro e fora da selecao")
            item = project(row, ITEM_FIELDS)
            account = item.get("client_account_display")
            mapped = account_map.get(item.get("client_id"))
            require(account is None or (isinstance(account, str) and 0 < len(account.strip()) <= 200),
                    f"{item['item_id']}: account invalido")
            require(not (account and mapped) or account.strip() == mapped.strip(),
                    f"{item['item_id']}: account diverge da carteira confirmada")
            if account or mapped:
                item["client_account_display"] = (account or mapped).strip()
            item["group_ids"] = item_groups(row)
            if len(item["group_ids"]) == 1:
                sole_group = item["group_ids"][0]
                require(item.get("group_id") in (None, sole_group),
                        f"{item['item_id']}: group_id contradiz group_ids")
                item["group_id"] = sole_group
            else:
                require(item.get("group_id") is None,
                        f"{item['item_id']}: grupo singular ambiguo em item multigrupo")
            item.setdefault("last_reviewed_at", row.get("last_reviewed_as_of"))
            for gid in item["group_ids"]:
                require(item.get("client_id") == catalog[gid]["client_id"],
                        f"{item['item_id']}: cliente divergente")
            require(item.get("status") in ITEM_STATUSES, f"{item['item_id']}: status invalido")
            require(isinstance(item.get("evidence_ids"), list) and item["evidence_ids"],
                    f"{item['item_id']}: falta evidencia")
            if item["status"] == "concluida":
                require(item.get("completion_evidence_ids"), f"{item['item_id']}: conclusao sem evidencia")
            if item["status"] == "cancelada":
                require(item.get("cancellation_evidence_ids") or item.get("completion_evidence_ids"),
                        f"{item['item_id']}: cancelamento sem evidencia")
            for field in ("first_seen_at", "last_evidence_at", "last_reviewed_at"):
                before_cutoff(item.get(field), cutoff, f"{item['item_id']} {field}")
            due = item.get("due_at")
            if due is not None:
                parse_time(due, f"{item['item_id']} due_at")
                expected = "datetime" if "T" in due else "date"
                require(item.get("due_precision") in (None, expected), "Precisao do prazo divergente")
            validate_explicit_timing(item, cutoff)
            out["items"].append(item)
        for row in index(state.get("evidence", []), "evidence_id", "evidence").values():
            if row.get("group_id") in selected:
                evidence = project(row, EVIDENCE_FIELDS)
                before_cutoff(evidence.get("message_at"), cutoff, evidence["evidence_id"])
                before_cutoff(evidence.get("message_date"), cutoff, evidence["evidence_id"])
                out["evidence"].append(evidence)
        for row in index(state.get("communication_cases", []), "case_id", "cases").values():
            if row.get("group_id") in selected:
                case = project(row, CASE_FIELDS)
                require(case.get("client_id") == catalog[case["group_id"]]["client_id"],
                        f"{case['case_id']}: cliente divergente")
                require(case.get("status") in CASE_STATUSES and case.get("case_type") in CASE_TYPES,
                        f"{case['case_id']}: caso invalido")
                require(case["status"] != "corrected" or case.get("correction_evidence_ids"),
                        f"{case['case_id']}: correcao sem evidencia")
                out["communication_cases"].append(case)
        item_index = index(out["items"], "item_id", "export.items")
        evidence_index = index(out["evidence"], "evidence_id", "export.evidence")
        source_people = index(state.get("people", []), "person_id", "people")
        selected_events = []
        for row in index(state.get("events", []), "event_id", "events").values():
            require(row.get("item_id") in source_items, f"{row['event_id']}: evento sem item")
            if row["item_id"] in item_index:
                selected_events.append(project(row, EVENT_FIELDS))
        needed_people = set()
        for key, value in references([out["items"], out["communication_cases"], selected_events]):
            if key in {"owner_person_ids", "other_response_author_person_ids"}:
                require(isinstance(value, list), "Lista de pessoas invalida")
                needed_people.update(value)
            elif key in {"response_author_person_id", "promised_by_person_id", "person_id"} and value is not None:
                needed_people.add(value)
        for pid in sorted(needed_people):
            require(pid in source_people, f"Pessoa inexistente: {pid}")
            out["people"].append(project(source_people[pid], PEOPLE_FIELDS))
        person_index = index(out["people"], "person_id", "export.people")
        for item in out["items"]:
            validate_refs(item, evidence_index, item_index, person_index, set(item["group_ids"]))
        for case in out["communication_cases"]:
            validate_refs(case, evidence_index, item_index, person_index, {case["group_id"]})
        for person in out["people"]:
            validate_refs(person, evidence_index, item_index, person_index, selected)
        for group in out["groups"]:
            validate_refs(group, evidence_index, item_index, person_index, {group["group_id"]})
        for event in selected_events:
            parse_time(event.get("recorded_at"), "event.recorded_at", optional=True)
            validate_refs(event, evidence_index, item_index, person_index,
                          set(item_index[event["item_id"]]["group_ids"]))
            out["events"].append(event)
    statuses = Counter(item["status"] for item in out["items"])
    cases = Counter(case["status"] for case in out["communication_cases"])
    out["summary"] = {
        "selected_groups": len(selected), "analyzed_groups": 0 if blocked else len(accessed),
        "total_items": len(out["items"]),
        "open_items": sum(n for status_key, n in statuses.items() if status_key not in {"concluida", "cancelada"}),
        "completed_items": statuses["concluida"], "item_statuses": dict(statuses),
        "communication_cases": len(out["communication_cases"]),
        "open_communication_cases": cases["open"], "case_statuses": dict(cases),
        "groups_with_pending_media": sum(bool(group["pending_media"]) for group in out["groups"]),
    }
    if out["summary"]["groups_with_pending_media"]:
        note = "Cobertura textual não inclui mídias pendentes; ausência de confirmação não prova falta de execução."
        if note not in out["limitations"]:
            out["limitations"].append(note)
    if run_id is None:
        # Corte e updated_at estao no envelope; o restante do conteudo permitido
        # tambem integra a identidade para nao reutilizar um ID imutavel quando
        # uma referencia preservada ou configuracao mudar. Diagnosticos nao entram.
        canonical = json.dumps(out, ensure_ascii=False, sort_keys=True,
                               separators=(",", ":"), allow_nan=False)
        out["run_id"] = "radar-" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:24]
    for document in (out, settings):
        require(len(encode(document)) <= MAX_BYTES, "Envelope excede limite de 2 MiB")
    return out, settings

def encode(document):
    return (json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("utf-8")

def validate_output_directory(directory):
    target, allowed = Path(directory).resolve(), PRIVATE_OUTPUT_ROOT.resolve()
    require(target == allowed or target.is_relative_to(allowed),
            "Saida permitida somente em outputs/whatsapp-radar-clientes/crm/")
    return target

def atomic_export(path, payload, immutable=False):
    if immutable and path.exists():
        require(path.read_bytes() == payload, f"run_id existente com conteudo diferente: {path.name}")
        return
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    try:
        with temporary.open("xb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()

def export_files(state_path, config_path, execution_path, *, output_dir=None,
                 settings_version, report_date=None, run_id=None):
    paths = [Path(path).resolve() for path in (state_path, config_path, execution_path)]
    originals = [path.read_bytes() for path in paths]
    documents = [json.loads(raw.decode("utf-8-sig")) for raw in originals]
    run, settings = build_exports(*documents, settings_version=settings_version,
                                 report_date=report_date, run_id=run_id)
    output = validate_output_directory(output_dir or PRIVATE_OUTPUT_ROOT)
    output.mkdir(parents=True, exist_ok=True)
    run_path = output / f"run-{run['run_id']}.json"
    settings_path = output / f"settings-v{settings_version}.json"
    require(all(path not in paths for path in (run_path, settings_path)), "Destino colide com fonte")
    require(originals == [path.read_bytes() for path in paths], "Fontes mudaram durante exportacao")
    atomic_export(run_path, encode(run), immutable=True)
    atomic_export(settings_path, encode(settings))
    require(originals == [path.read_bytes() for path in paths], "Fontes mudaram durante exportacao")
    return {"run_path": str(run_path), "settings_path": str(settings_path),
            "run_id": run["run_id"], "status": run["status"], "summary": run["summary"],
            "analysis_cutoff": run["analysis_cutoff"], "generated_at": run["generated_at"],
            "run_bytes": run_path.stat().st_size, "published": False}

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, default=RADAR_ROOT / "estado.json")
    parser.add_argument("--config", type=Path, default=RADAR_ROOT / "config.json")
    parser.add_argument("--execution", type=Path, default=RADAR_ROOT / "execucao.json")
    parser.add_argument("--output-dir", type=Path, default=PRIVATE_OUTPUT_ROOT)
    parser.add_argument("--settings-version", type=int, required=True)
    parser.add_argument("--report-date")
    parser.add_argument("--run-id")
    args = parser.parse_args(argv)
    try:
        result = export_files(args.state, args.config, args.execution, output_dir=args.output_dir,
                              settings_version=args.settings_version,
                              report_date=args.report_date, run_id=args.run_id)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(json.dumps({"exported": False, "published": False, "error": str(exc)},
                         ensure_ascii=False), file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())

