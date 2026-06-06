import asyncio
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import httpx

# =====================================================================
# CONFIGURAZIONE SERVER HTTP (INTERFACCIA MUSESCORE)
# =====================================================================
pending_command = None
command_response = None
response_ready = threading.Event()


class MuseScoreHTTPHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        return  # Silenzia i log di rete per mantenere pulito il terminale

    def do_GET(self):
        global pending_command
        if self.path == "/get_command":
            if pending_command:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(pending_command).encode("utf-8"))
                pending_command = None
            else:
                self.send_response(204)
                self.end_headers()

    def do_POST(self):
        global command_response
        if self.path == "/post_response":
            content_length = int(self.headers["Content-Length"])
            post_data = self.rfile.read(content_length)
            command_response = json.loads(post_data.decode("utf-8"))
            self.send_response(200)
            self.end_headers()
            response_ready.set()


def start_http_server():
    server = HTTPServer(("127.0.0.1", 8765), MuseScoreHTTPHandler)
    server.serve_forever()


# Avvio del server in background
server_thread = threading.Thread(target=start_http_server, daemon=True)
server_thread.start()
print("[Python Server] In ascolto sulla porta 8765...")


def send_musescore_command(action, params=None):
    global pending_command, command_response
    response_ready.clear()
    command_response = None

    pending_command = {"action": action, "params": params or {}}

    if response_ready.wait(timeout=5.0):
        return command_response
    else:
        raise TimeoutError(
            "MuseScore non ha risposto. Il plugin è attivo nel menu di MuseScore?"
        )


# =====================================================================
# CONFIGURAZIONE AI (OLLAMA & TOOLS)
# =====================================================================
OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL_NAME = "qwen2.5-coder:3b"

TOOLS_SPEC = [
    {
        "type": "function",
        "function": {
            "name": "getScore",
            "description": "Ottiene informazioni sullo spartito attuale (struttura, battute presenti, note inserite).",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "addNote",
            "description": "Inserisce una nota musicale nello spartito di MuseScore.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pitch": {
                        "type": "integer",
                        "description": "Il valore MIDI della nota (es. 60 per il Do centrale, 62 per il Re, ecc.).",
                    },
                    "measure": {
                        "type": "integer",
                        "description": "L'indice della battuta in cui inserire la nota (0 per la prima battuta).",
                        "default": 0,
                    },
                    "duration_type": {
                        "type": "string",
                        "description": "Il tipo di durata. Può essere 'semiminima', 'croma', 'minima', 'semibreve'.",
                        "default": "semiminima",
                    },
                    "advanceCursorAfterAction": {
                        "type": "boolean",
                        "description": "Se True, sposta il cursore in avanti dopo aver inserito la nota.",
                        "default": True,
                    },
                },
                "required": [
                    "pitch",
                    "measure",
                    "duration_type",
                    "advanceCursorAfterAction",
                ],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "deleteMeasure",
            "description": "Svuota o elimina il contenuto di una o più battute consecutive dello spartito.",
            "parameters": {
                "type": "object",
                "properties": {
                    "measure": {
                        "type": "integer",
                        "description": "Il numero della battuta da cui iniziare l'eliminazione (1 per la prima battuta, 2 per la seconda, ecc.)."
                    },
                    "count": {
                        "type": "integer",
                        "description": "Il numero totale di battute consecutive da eliminare. Di default è 1.",
                        "default": 1
                    }
                },
                "required": ["measure"]
            }
        },
    },
{
    "type": "function",
    "function": {
        "name": "transposeStaff",
        "description": "Traspone o sposta l'altezza (pitch) di tutte le note di un intero rigo musicale.",
        "parameters": {
            "type": "object",
            "properties": {
                "staff": {
                    "type": "integer",
                    "description": "L'indice del rigo da trasporre: 0 per il rigo superiore, 1 per il rigo inferiore."
                },
                "direction": {
                    "type": "string",
                    "description": "La direzione del movimento: 'up' per alzare, 'down' per abbassare.",
                    "enum": ["up", "down"]
                },
                "amount": {
                    "type": "string",
                    "description": "L'entità dello spostamento: 'octave' per spostare di un'ottava completa, 'semitone' per spostare di un semitono.",
                    "enum": ["octave", "semitone"]
                }
            },
            "required": ["staff", "direction", "amount"]
        }
    },
},
{
    "type": "function",
    "function": {
        "name": "intelligentBassTranspose",
        "description": "Adatta automaticamente un rigo pensato per Tuba trasformandolo per un Basso Elettrico a 4 corde. Analizza lo spartito e alza di un'ottava INTERE battute SOLO se contengono note sotto il Mi grave (MIDI 28).",
        "parameters": {
            "type": "object",
            "properties": {
                "staff": {
                    "type": "integer",
                    "description": "L'indice del rigo del basso da ottimizzare: USA TASSATIVAMENTE 0 per il primo rigo (o rigo unico), 1 per il secondo rigo."
                }
            },
            "required": ["staff"]
        }
    },
}
]


def parse_duration(duration_type):
    mapping = {
        "semibreve": {"numerator": 1, "denominator": 1},
        "minima": {"numerator": 1, "denominator": 2},
        "semiminima": {"numerator": 1, "denominator": 4},
        "croma": {"numerator": 1, "denominator": 8},
        "semicroma": {"numerator": 1, "denominator": 16},
    }
    res = mapping.get(
        str(duration_type).lower(), {"numerator": 1, "denominator": 4}
    )
    return {"numerator": int(res["numerator"]), "denominator": int(res["denominator"])}

def clean_and_parse_json(s):
    """Pulisce a fondo le stringhe generate dagli LLM estraendo ed eseguendo il parsing del JSON in modo sicuro."""
    if not isinstance(s, str):
        return s

    s = s.strip()

    # 🛡️ SAFE ZONE: Usiamo \x60 (codice esadecimale del backtick `)
    # per evitare che il copia-incolla o il markdown corrompano il codice Python
    backticks_gate = "\x60\x60\x60"
    if s.startswith(backticks_gate):
        s = re.sub(r"^\x60\x60\x60[a-zA-Z]*\n", "", s)
        s = re.sub(r"\n\x60\x60\x60$", "", s)
        s = s.strip()

    # Isola l'oggetto JSON principale prendendo la prima '{' e l'ultima '}'
    if "{" in s:
        start_idx = s.find("{")
        end_idx = s.rfind("}")
        if start_idx != -1 and end_idx != -1:
            s = s[start_idx:end_idx + 1]

    # Sanificazione spazi speciali, ritorni a capo e virgolette curve
    s = s.replace("\xa0", " ").replace("\r", "")
    s = s.replace("“", '"').replace("”", '"').replace("‘", "'").replace("’", "'")

    # Rimuove commenti inline generati per errore dall'LLM
    clean_lines = []
    for line in s.splitlines():
        if "//" in line:
            line = line.split("//")[0]
            clean_lines.append(line)
            s = "\n".join(clean_lines).strip()

    # Rimuove virgole finali (trailing commas) che rompono il json standard
    s = re.sub(r",\s*([\]}])", r"\1", s)

    return json.loads(s)


async def prompt_ollama(user_input):
    valid_tools = [t["function"]["name"] for t in TOOLS_SPEC]

    messages = [
        {
            "role": "system",
            "content": (
                f"Sei un assistente musicale per MuseScore. Puoi usare SOLO: {valid_tools}.\n"
                "Quando l'utente ti chiede qualcosa, rispondi usando lo strumento o scrivendo SOLO il JSON della funzione.\n"
                "NON inserire MAI commenti testuali o note (come // commento) all'interno del codice JSON.\n"
                "Nei parametri, assegna a 'duration_type' uno di questi valori: 'semiminima', 'croma', 'minima', 'semibreve'.\n"
                "Usa SEMPRE lo 0 come indice per il primo rigo musicale.\n"
                "Rispondi sempre in italiano."
            ),
        },
        {"role": "user", "content": user_input},
    ]

    print(f"\n[Ollama] Lavoro in corso con {MODEL_NAME}...")
    async with httpx.AsyncClient() as http_client:
        try:
            response = await http_client.post(
                OLLAMA_URL,
                json={
                    "model": MODEL_NAME,
                    "messages": messages,
                    "tools": TOOLS_SPEC,
                    "stream": False,
                },
                timeout=30.0,
            )
            res_json = response.json()
            message = res_json.get("message", {})
            content = message.get("content", "").strip()

            action = None
            args = {}

            # CASO 1: Chiamata nativa dello strumento (Ollama Tool Calling)
            if "tool_calls" in message and message["tool_calls"]:
                tool_call = message["tool_calls"][0]
                action = tool_call["function"]["name"]
                raw_args = tool_call["function"].get("arguments", {})
                try:
                    if isinstance(raw_args, str):
                        args = clean_and_parse_json(raw_args)
                    else:
                        args = raw_args
                        print(f" -> [Tool Nativo Rilevato] {action}")
                except Exception:
                    action = None  # Se corrotto, forza il fallback sul testo libero qui sotto

            # CASO 2: Fallback se il modello scrive il JSON nel corpo del testo
            if not action and "{" in content and "name" in content:
                try:
                    parsed_tool = clean_and_parse_json(content)
                    action = parsed_tool.get("name")
                    args = parsed_tool.get("arguments", parsed_tool.get("params", {}))
                    print(f" -> [Tool Testuale Intercettato] {action}")
                except Exception as e:
                    return f"Formato JSON non decodificabile: {e}\nTesto originale: {content}"

            if action:
                if action not in valid_tools:
                    return f"Comando non valido ({action})."

                for k, v in list(args.items()):
                    if isinstance(v, list) and len(v) > 0:
                        args[k] = v[0]
                        if isinstance(v, dict) and "value" in v:
                            args[k] = v["value"]

                # ESECUZIONE: addNote
                if action == "addNote":
                    args["pitch"] = 60 if args.get("pitch") is None or args.get("pitch") == "" else int(args["pitch"])
                    args["measure"] = 0 if args.get("measure") is None or int(args.get("measure", -1)) < 0 else int(args["measure"])
                    dtype = args.get("duration_type", "semiminima")
                    args["duration"] = parse_duration(dtype)

                    if "duration_type" in args: del args["duration_type"]
                    if "advanceCursorAfterAction" not in args: args["advanceCursorAfterAction"] = True

                    ms_res = await asyncio.to_thread(send_musescore_command, "addNote", args)
                    return f"Nota {args['pitch']} aggiunta. Risposta MuseScore: {ms_res}"

                # ESECUZIONE: deleteMeasure
                if action == "deleteMeasure":
                    measure_idx = int(args.get("measure", 1))
                    count_num = int(args.get("count", 1))
                    ms_res = await asyncio.to_thread(send_musescore_command, "deleteMeasure", {"measure": measure_idx, "count": count_num})
                    return f"Eliminate {count_num} battute. Risposta MuseScore: {ms_res}"

                # ESECUZIONE: transposeStaff
                if action == "transposeStaff":
                    staff_idx = int(args.get("staff", 0))
                    direction_str = str(args.get("direction", "up")).lower().strip()
                    amount_str = str(args.get("amount", "octave"))
                    ms_res = await asyncio.to_thread(send_musescore_command, "transposeStaff", {"staff": staff_idx, "direction": direction_str, "amount": amount_str})
                    return f"Rigo {staff_idx} trasposto. Risposta MuseScore: {ms_res}"

                # 🎸 ESECUZIONE: ADATTAMENTO INTELLIGENTE PER BASSO ELETTRICO
                if action == "intelligentBassTranspose":
                    staff_idx = int(args.get("staff", 0))

                    # Forza lo 0 se l'utente lo ha inserito nel prompt testuale
                    if "0" in user_input:
                        staff_idx = 0

                    print(f" -> [Analisi] Avvio ottimizzazione intelligente per Basso sul rigo {staff_idx}...")

                    score_data = await asyncio.to_thread(send_musescore_command, "getScore")
                    if not score_data:
                        return "Impossibile analizzare lo spartito. Risposta vuota da MuseScore."

                    root_obj = score_data.get("result", score_data)
                    analysis_obj = root_obj.get("analysis", {})
                    measures = analysis_obj.get("measures", [])

                    if not measures:
                        return "Impossibile analizzare lo spartito. Nessuna battuta trovata."

                    # Protezione: Reindirizzamento automatico a staff0 se l'unico rigo esistente nello spartito
                    staff_key = f"staff{staff_idx}"
                    staves_disponibili = list(measures[0].get("elements", {}).keys())
                    if staff_key not in staves_disponibili and "staff0" in staves_disponibili:
                        print(f"    [Auto-Correzione] Rigo {staff_key} non trovato. Reindirizzo forzato su 'staff0'.")
                        staff_idx = 0
                        staff_key = "staff0"

                    modified_measures_count = 0

                    for idx, measure in enumerate(measures):
                        elements = measure.get("elements", {}).get(staff_key, [])
                        notes_in_measure = []
                        for element in elements:
                            if element.get("type") == "CHORD":
                                notes_in_measure.extend(element.get("notes", []))

                        needs_octave_up = False

                        if notes_in_measure:
                            valori_pitch = [n.get("pitch", "N/A") for n in notes_in_measure]
                            print(f"    [Controllo] Battuta {idx + 1} contiene note con MIDI Pitch: {valori_pitch}")
                        else:
                            print(f"    [Controllo] Battuta {idx + 1} non contiene note.")

                        for note in notes_in_measure:
                            pitch = note.get("pitch", 40)
                            if pitch < 28:
                                needs_octave_up = True
                                break

                        if needs_octave_up:
                            print(f"    -> Battuta {idx + 1}: Note sotto il Mi grave rilevate! Trasposizione +1 ottava.")
                            await asyncio.to_thread(
                            send_musescore_command,
                            "transposeMeasure",
                            {"staff": staff_idx, "measure": idx + 1, "direction": "up", "amount": "octave"}  # <--- AGGIUNTO +1 QUI
                            )
                    modified_measures_count += 1

                    return f"Ottimizzazione completata sul rigo {staff_idx}. Alzate di un'ottava {modified_measures_count} battute critiche (Soglia Mi grave MIDI 28)."

            return content if content else "Nessuna azione intrapresa."

        except Exception as e:
            return f"Errore durante la comunicazione o l'esecuzione: {e}"


# LOOP PRINCIPALE ASINCRONO
# =====================================================================
async def main():
    print("🤖 Assistente MuseScore pronto e connesso tramite Server HTTP!")
    print("Assicurati che il plugin sia avviato dentro MuseScore (Plugin -> MuseScore API Server).")
    print("Digita un comando (es: 'Adatta il rigo 0 per basso a 4 corde') o 'exit' per uscire.\n")

    while True:
        try:
            user_input = input("Tu > ")
            if user_input.lower() in ["exit", "quit"]:
                print("Arrivederci!")
                break
            if not user_input.strip():
                continue

            reply = await prompt_ollama(user_input)
            print(f"Assistente > {reply}\n")

        except (KeyboardInterrupt, EOFError):
            print("\nChiusura in corso...")
            break
        except Exception as e:
            print(f"Errore nel ciclo principale: {e}\n")


if __name__ == "__main__":
    asyncio.run(main())
