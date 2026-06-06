import QtQuick 2.15
import MuseScore 3.0

MuseScore {
	id: root
	menuPath: "Plugins.MuseScore API Server"
	description: "Exposes MuseScore API via Native HTTP Polling"
	version: "4.0"

	// Indirizzo del mini-server Python che andremo ad avviare
	property string baseUrl: "http://127.0.0.1:8765"

	property var selectionState: ({
		startStaff: 0,
		endStaff: 1,
		startTick: 0,
		elements: []
	})

	// Il Timer che interroga Python ogni 250 millisecondi
	Timer {
		id: pollTimer
		interval: 250
		running: true
		repeat: true
		onTriggered: fetchCommand()
	}

	function fetchCommand() {
		var xhr = new XMLHttpRequest();
		xhr.open("GET", baseUrl + "/get_command", true);

		xhr.onreadystatechange = function() {
			if (xhr.readyState === XMLHttpRequest.DONE) {
				if (xhr.status === 200 && xhr.responseText.trim() !== "") {
					console.log("Received command from Python!");
					try {
						var command = JSON.parse(xhr.responseText);
						var result = processCommand(command);
						sendResponse({ status: "success", result: result });
					} catch (e) {
						sendResponse({ status: "error", message: e.toString() });
					}
				}
			}
		}
		xhr.send();
	}

	function sendResponse(responseObj) {
		var xhr = new XMLHttpRequest();
		xhr.open("POST", baseUrl + "/post_response", true);
		xhr.setRequestHeader("Content-Type", "application/json");
		xhr.send(JSON.stringify(responseObj));
	}

	// =========================================================================
	// DISPATCHER DEI COMANDI
	// =========================================================================
	function processCommand(command) {
		console.log("Processing action: " + command.action);
		switch(command.action) {
			case "getScore":                return getScore(command.params);
			case "syncStateToSelection":    return syncStateToSelection();
			case "ping":                    return "pong";
			case "undo":                    return "undo";
			case "goToBeginningOfScore":    return goToBeginningOfScore();
			case "processSequence":         return processSequence(command.params);
			case "cmd":
			if (!command.params || !command.params.command) {
				throw new Error("Missing 'command' parameter");
			}
			return executeWithUndo(function() {
				cmd(command.params.command);
				return { success: true, message: "Executed: " + command.params.command };
			});
			case "getCursorInfo":           return getCursorInfo(command.params);
			case "goToMeasure":              return goToMeasure(command.params);
			case "goToFinalMeasure":        return goToFinalMeasure(command.params);
			case "nextElement":             return nextElement(command.params);
			case "prevElement":             return prevElement(command.params);
			case "nextStaff":                return nextStaff(command.params);
			case "prevStaff":                return prevStaff(command.params);
			case "selectCurrentMeasure":    return selectCurrentMeasure(command.params);
			case "selectCustomRange":       return selectCustomRange(command.params);
			case "addNote":                  return addNote(command.params);
			case "addRest":                  return addRest(command.params);
			case "setTimeSignature":        return setTimeSignature(command.params);
			case "setTempo":                return setTempo(command.params);
			case "appendMeasure":           return appendMeasure(command.params);
			case "insertMeasure":           return insertMeasure(command.params);
			case "deleteSelection":         return deleteSelection(command.params);
			case "deleteMeasure":           return deleteMeasure(command.params); 

			// Mappature per la trasposizione (Rigo intero o singola Battuta)
			case "transposeStaff":          return transposeStaff(command.params); 
			case "transposeMeasure":        return transposeMeasure(command.params); 

			default:
			throw new Error("Unknown command: " + command.action);
		}
	}

	// =========================================================================
	// FUNZIONE DI ELIMINAZIONE BATTUTA
	// =========================================================================
	function deleteMeasure(params) {
		if (!params || params.measure === undefined) 
		return { error: "Parametro 'measure' mancante" };
		if (!curScore) 
		return { error: "Nessuno spartito aperto" };

		var measureNumber = parseInt(params.measure);
		if (isNaN(measureNumber) || measureNumber < 1) 
		return { error: "Numero battuta non valido" };

		var count = params.count !== undefined ? parseInt(params.count) : 1;
		if (isNaN(count) || count < 1) count = 1;

		curScore.startCmd();

		try {
			curScore.selection.clear();

			var cursor = curScore.newCursor();
			cursor.rewind(0); 

			for (var i = 1; i < measureNumber; i++) {
				if (!cursor.nextMeasure()) {
					curScore.endCmd();
					return { error: "La battuta numero " + measureNumber + " non esiste." };
				}
			}

			var elementToSelect = null;
			if (cursor.segment && cursor.segment.elements) {
				for (var e = 0; e < cursor.segment.elements.length; e++) {
					var el = cursor.segment.elements[e];
					if (el) {
						if (el.notes && el.notes.length > 0) {
							elementToSelect = el.notes[0];
						} else {
							elementToSelect = el;
						}
						break;
					}
				}
			}

			if (!elementToSelect && cursor.element) {
				elementToSelect = cursor.element.notes ? cursor.element.notes[0] : cursor.element;
			}

			if (!elementToSelect) {
				curScore.endCmd();
				return { error: "Nessun elemento valido trovato nella battuta " + measureNumber };
			}

			curScore.selection.select(elementToSelect);

			for (var m = 0; m < count; m++) {
				cmd("select-next-measure"); 
			}

			for (var s = 0; s < 20; s++) {
				cmd("select-staff-below");
			}

			cmd("time-delete");

			curScore.selection.clear();
			curScore.endCmd();

			return { 
				success: true, 
				message: count + " battute eliminate con successo a partire dalla battuta " + measureNumber 
			};

		} catch (e) {
			curScore.endCmd(true); // Rollback
			return { error: "Errore durante l'eliminazione multipla: " + e.toString() };
		}
	}

	// =========================================================================
	// TRASPOSIZIONE SINGOLA BATTUTA (Corretta - Modifica Diretta API)
	// =========================================================================
	function transposeMeasure(params) {
		if (!curScore) return { error: "Nessuno spartito aperto" };
		if (!params || params.measure === undefined) return { error: "Parametro 'measure' mancante" };

		var measureNumber = parseInt(params.measure);
		var staffIndex = params.staff !== undefined ? parseInt(params.staff) : 0; 

		var direction = params.direction || "up";
		var amount = params.amount || "octave";

		// Calcola lo spostamento in semitoni (12 per ottava, 1 per semitono)
		var pitchChange = 0;
		if (amount === "octave") pitchChange = 12;
		else if (amount === "semitone") pitchChange = 1;

		if (direction === "down") {
			pitchChange = -pitchChange;
		}

		if (pitchChange === 0) return { error: "Spostamento pitch non valido" };

		// [DEBUG] Log dei parametri esatti ricevuti da Python
		console.log("[DEBUG QML] ==========================================");
		console.log("[DEBUG QML] Ricevuto comando transposeMeasure da Python!");
		console.log("[DEBUG QML] -> Richiesta Battuta (measureNumber):", measureNumber);
		console.log("[DEBUG QML] -> Richiesto Rigo (staffIndex):", staffIndex);
		console.log("[DEBUG QML] -> Spostamento Pitch calcolato:", pitchChange);

		curScore.startCmd();

		try {
			// Svuota la selezione grafica per evitare conflitti visivi
			curScore.selection.clear();

			// Navigazione tra le battute
			var currentMeasure = curScore.firstMeasure;
			var mCount = 1;
			while (currentMeasure && mCount < measureNumber) {
				currentMeasure = currentMeasure.nextMeasure;
				mCount++;
			}

			if (!currentMeasure) {
				console.log("[DEBUG QML] ERRORE: La battuta", measureNumber, "NON ESISTE. Il conteggio si è fermato a:", mCount);
				curScore.endCmd();
				return { error: "La battuta numero " + measureNumber + " non esiste." };
			}

			console.log("[DEBUG QML] OK: Battuta agganciata nel loop. Indice reale:", mCount);

			var notesTransposedCount = 0;
			var segment = currentMeasure.firstSegment;
			var segmentsChecked = 0;

			// Scansiona tutti i segmenti all'interno della battuta
			while (segment) {
				segmentsChecked++;
				for (var voice = 0; voice < 4; voice++) {
					var track = staffIndex * 4 + voice;
					var el = segment.elementAt(track);

					if (el) {
						// Se vuoi un log ultra-verboso di ogni elemento, scommenta la riga sotto:
						// console.log("[DEBUG QML] Traccia", track, "| Trovato elemento tipo:", el.type);

						if (el.type === Element.CHORD) {
							for (var n = 0; n < el.notes.length; n++) {
								var oldPitch = el.notes[n].pitch;
								el.notes[n].pitch += pitchChange;
								console.log("[DEBUG QML] -> NOTA TRASPOSTA! Traccia:", track, "| Vecchio Pitch:", oldPitch, "-> Nuovo:", el.notes[n].pitch);
								notesTransposedCount++;
							}
						}
					}
				}
				segment = segment.nextInMeasure; 
			}

			console.log("[DEBUG QML] Fine battuta. Segmenti analizzati:", segmentsChecked, "| Note totali modificate:", notesTransposedCount);
			if (notesTransposedCount === 0) {
				console.log("[DEBUG QML] ATTENZIONE: Zero note modificate! La battuta era vuota (solo pause) o lo 'staffIndex' cercato è sbagliato.");
			}
			console.log("[DEBUG QML] ==========================================");

			curScore.endCmd();

			return { 
				success: true, 
				message: "Battuta " + measureNumber + " (rigo " + staffIndex + ") ottimizzata. Trasposte " + notesTransposedCount + " note." 
			};

		} catch (e) {
			console.log("[DEBUG QML] ERRORE CRITICO DURANTE LA TRASPOSIZIONE:", e.toString());
			curScore.endCmd(true); 
			return { error: "Errore durante la trasposizione della battuta: " + e.toString() };
		}
	}




	// TRASPOSIZIONE RIGO INTERO
	// =========================================================================
	function transposeStaff(params) {
		if (!curScore) return { error: "Nessuno spartito aperto" };

		var staffIndex = params.staff !== undefined ? parseInt(params.staff) : 1;
		if (isNaN(staffIndex)) staffIndex = 1;

		var direction = params.direction || "up";
		var amount = params.amount || "octave";

		var commandName = "pitch-up-octave";
		if (direction === "down" && amount === "octave") commandName = "pitch-down-octave";
		else if (direction === "up" && amount === "semitone") commandName = "pitch-up";
		else if (direction === "down" && amount === "semitone") commandName = "pitch-down";

		curScore.startCmd();

		try {
			curScore.selection.clear();

			var cursor = curScore.newCursor();
			cursor.rewind(0);
			cursor.staffIdx = staffIndex;
			cursor.voice = 0;

			var elementToSelect = null;
			while (cursor.segment) {
				if (cursor.element && cursor.element.type === Element.CHORD) {
					elementToSelect = cursor.element.notes[0];
					break;
				}
				cursor.next();
			}

			if (!elementToSelect) {
				cursor.rewind(0);
				cursor.staffIdx = staffIndex;
				if (cursor.element) {
					elementToSelect = cursor.element.notes ? cursor.element.notes[0] : cursor.element;
				}
			}

			if (!elementToSelect) {
				curScore.endCmd();
				return { error: "Nessun elemento trovato nel rigo " + staffIndex };
			}

			curScore.selection.select(elementToSelect);

			var totalMeasures = curScore.nmeasures || 100;
			for (var i = 0; i < totalMeasures + 10; i++) {
				cmd("select-next-measure");
			}

			cmd(commandName);

			curScore.selection.clear();
			curScore.endCmd();

			return { success: true, message: "Tutte le note del rigo " + staffIndex + " spostate." };

		} catch (e) {
			curScore.endCmd(true);
			return { error: "Errore trasposizione rigo: " + e.toString() };
		}
	}

	// =========================================================================
	// FUNZIONE DI LETTURA STRUTTURA ED ESTRAZIONE NOTE (CORRETTA!)
	// =========================================================================
	function getScore(params) {
		if (!curScore) return { error: "No score open" };

		var startM = (params && params.startMeasure) ? parseInt(params.startMeasure) : 1;
		var endM = (params && params.endMeasure) ? parseInt(params.endMeasure) : curScore.nmeasures;

		var score = { title: curScore.title || "Untitled", numMeasures: curScore.nmeasures, measures: [] };

		var currentMeasure = curScore.firstMeasure;
		var mCount = 1;

		while (currentMeasure && mCount <= endM) {
			if (mCount >= startM) {
				var measureObj = { 
					measure: mCount, 
					startTick: currentMeasure.firstSegment ? currentMeasure.firstSegment.tick : 0, 
					elements: {} 
				};

				for (var j = 0; j < curScore.nstaves; j++) {
					measureObj.elements["staff" + j] = [];
				}

				var segment = currentMeasure.firstSegment;
				while (segment) {
					for (var j = 0; j < curScore.nstaves; j++) {
						for (var voice = 0; voice < 4; voice++) {
							var track = j * 4 + voice;
							var element = segment.elementAt(track);

							if (element && element.type === Element.CHORD) {
								var chordObj = {
									type: "CHORD",
									notes: []
								};

								for (var n = 0; n < element.notes.length; n++) {
									chordObj.notes.push({
										pitch: element.notes[n].pitch,
										tpc: element.notes[n].tpc
									});
								}

								measureObj.elements["staff" + j].push(chordObj);
							}
						}
					}
					segment = segment.nextInMeasure; // 🛡️ FIX: Resta rigorosamente dentro questa battuta!
				}

				score.measures.push(measureObj);
			}
			currentMeasure = currentMeasure.nextMeasure; // 🛡️ FIX: Proprietà corretta per passare alla battuta successiva!
			mCount++;
		}

		return { success: true, analysis: score };
	}

	// =========================================================================
	// UTILITY FUNCTIONS (Stabili)
	// =========================================================================
	function validateParams(params, required) {
		if (!params) return { error: "Parameters object missing" };
		var missing = [];
		for (var i = 0; i < required.length; i++) {
			if (params[required[i]] === undefined) missing.push(required[i]);
		}
		return missing.length > 0 ? { error: "Missing required parameters: " + missing.join(", ") } : { valid: true };
	}

	function executeWithUndo(operation) {
		if (!curScore) return { error: "No score open" };
		curScore.startCmd();
		try {
			var result = operation();
			curScore.endCmd();
			return result;
		} catch (e) {
			curScore.endCmd(true);
			return { error: e.toString() };
		}
	}

	function getTpcName(tpc) {
		var tpcNames = ["Cbb", "Gbb", "Dbb", "Abb", "Ebb", "Bbb", "Fb", "Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#", "G#", "D#", "A#", "E#", "B#", "F##", "C##", "G##", "D##", "A##", "E##", "B##", "F###"];
		if (tpc >= 0 && tpc < tpcNames.length) return tpcNames[tpc];
		return "Unknown";
	}

	function createCursor(params) {
		if (!curScore) throw new Error("No score open");
		if (!params || Object.keys(params).length === 0) params = selectionState;
		var cursor = curScore.newCursor();
		cursor.inputStateMode = Cursor.INPUT_STATE_SYNC_WITH_SCORE;
		if (params.startStaff !== undefined) cursor.staffIdx = params.startStaff;
		if (params.voice !== undefined) cursor.voice = params.voice;
		if (params.startTick !== undefined) {
			try { cursor.rewindToTick(params.startTick); } 
			catch (e) { cursor.rewind(0); while (cursor.tick < params.startTick && cursor.next()) {} }
		} else { cursor.rewind(0); }
		return cursor;
	}

	function initCursorState() {
		if (!curScore) return "No score open";
		return executeWithUndo(function() {
			var cursor = curScore.newCursor();
			cursor.inputStateMode = Cursor.INPUT_STATE_NONE;
			cursor.rewind(0);

			var startTick = cursor.tick;
			var element = cursor.element;

			if (!element) {
				cursor.next();
				element = cursor.element;
			}

			selectionState = {
				startStaff: cursor.staffIdx,
				endStaff: cursor.staffIdx + 1,
				startTick: startTick,
				elements: element ? [processElement(element)] : []
			};
			return "Initialized";
		});
	}

	function processElement(element) {
		if (!element) return null;
		if (element.name !== "Chord" && element.name !== "Rest") return null;
		var base = { name: element.name, durationTicks: element.actualDuration ? element.actualDuration.ticks : 0 };
		if (element.name === "Chord") {
			base.notes = [];
			var notesObj = element.notes || {};
			var keys = Object.keys(notesObj);
			for (var k = 0; k < keys.length; k++) {
				var note = notesObj[keys[k]];
				if (note) base.notes.push({ pitchMidi: note.pitch, pitchName: getTpcName(note.tpc) });
			}
		}
		return base;
	}

	function undo() { return executeWithUndo(function() { cmd("undo"); return { success: true }; }); }
	function goToBeginningOfScore() { initCursorState(); return { success: true, currentSelection: selectionState }; }

	function processSequence(params) {
		if (!params || !params.sequence) return { error: "No sequence specified" };
		for (var i = 0; i < params.sequence.length; i++) processCommand(params.sequence[i]);
		return { success: true, currentSelection: selectionState };
	}

	function syncStateToSelection() {
		if (!curScore) return { error: "No score open" };
		var cursor = curScore.newCursor();
		cursor.rewind(0);
		selectionState = {
			startStaff: cursor.staffIdx,
			endStaff: cursor.staffIdx + 1,
			startTick: cursor.tick,
			elements: cursor.element ? [processElement(cursor.element)] : []
		};
		return { success: true, currentSelection: selectionState };
	}

	function getCursorInfo(params) { syncStateToSelection(); return { success: true, currentSelection: selectionState }; }

	function nextElement(params) {
		return executeWithUndo(function() {
			var cursor = createCursor();
			if (cursor.next()) {
				curScore.selection.clear();
				if (cursor.element) curScore.selection.select(cursor.element);
				return syncStateToSelection();
			}
			return { success: false, message: "End reached" };
		});
	}

	function prevElement(params) {
		return executeWithUndo(function() {
			var cursor = createCursor();
			if (cursor.prev()) {
				curScore.selection.clear();
				if (cursor.element) curScore.selection.select(cursor.element);
				return syncStateToSelection();
			}
			return { success: false, message: "Beginning reached" };
		});
	}

	function nextStaff(params) {
		return executeWithUndo(function() {
			var cursor = createCursor();
			if (cursor.staffIdx + 1 < curScore.nstaves) { cursor.staffIdx++; return syncStateToSelection(); }
			return { success: false };
		});
	}

	function prevStaff(params) {
		return executeWithUndo(function() {
			var cursor = createCursor();
			if (cursor.staffIdx > 0) { cursor.staffIdx--; return syncStateToSelection(); }
			return { success: false };
		});
	}

	function goToFinalMeasure(params) {
		return executeWithUndo(function() {
			var cursor = curScore.newCursor();
			cursor.rewind(0);
			while (cursor.nextMeasure()) {}
			return syncStateToSelection();
		});
	}

	function selectCurrentMeasure() { return { success: true }; }
	function selectCustomRange(params) { return { success: true }; }

	function addNote(params) {
		var validation = validateParams(params, ["pitch", "duration"]);
		if (!validation.valid) return validation;
		return executeWithUndo(function() {
			var cursor = createCursor();
			cursor.setDuration(params.duration.numerator, params.duration.denominator);
			cursor.addNote(params.pitch);
			if (params.advanceCursorAfterAction) cursor.next();
			return syncStateToSelection();
		});
	}

	function addRest(params) {
		if (!params || !params.duration) return { error: "Missing duration" };
		return executeWithUndo(function() {
			var cursor = createCursor();
			cursor.setDuration(params.duration.numerator, params.duration.denominator);
			cursor.addRest();
			return syncStateToSelection();
		});
	}

	function setTimeSignature(params) { return { success: true }; }
	function setTempo(params) { return { success: true }; }
	function appendMeasure(params) { return executeWithUndo(function() { cmd("append-measure"); return { success: true }; }); }
	function insertMeasure(params) { return executeWithUndo(function() { cmd("insert-measure"); return { success: true }; }); }
	function deleteSelection(params) { return executeWithUndo(function() { cmd("delete"); return { success: true }; }); }

	function goToMeasure(params) {
		if (!params || params.measure === undefined) return { error: "Missing measure" };
		return executeWithUndo(function() {
			var cursor = curScore.newCursor();
			cursor.rewind(0);
			for (var i = 1; i < params.measure; i++) {
				cursor.nextMeasure();
			}
			curScore.selection.clear();
			if (cursor.element) {
				if (cursor.element.notes && cursor.element.notes.length > 0) {
					curScore.selection.select(cursor.element.notes[0]);
				} else {
					curScore.selection.select(cursor.element);
				}
			} else if (cursor.segment) {
				curScore.selection.select(cursor.segment);
			}
			return syncStateToSelection();
		});
	}
}
