# 🎼 MuseScore AI Bridge

<p align="center">
  <img src="https://img.shields.io/badge/MuseScore-4.x-blue?style=for-the-badge&logo=musescore&logoColor=white" alt="MuseScore 4">
  <img src="https://img.shields.io/badge/Ollama-AI-orange?style=for-the-badge" alt="Ollama">
  <img src="https://img.shields.io/badge/Model-Qwen2.5--Coder-purple?style=for-the-badge" alt="Qwen2.5-Coder">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="MIT License">
</p>

---

## 🚀 Overview

**MuseScore AI Bridge** is an asynchronous Python-based system that allows you to control **MuseScore 4** using natural language via a local LLM (**Ollama** + **Qwen2.5-Coder**).

With this bridge, you can interact with your musical notation using voice-style text commands to insert notes, delete measures, or apply smart automation—such as automatically adapting low-brass parts for a standard 4-string electric bass.

---

## 🛠️ Installation & Setup

### 1. Start the Local AI Model (Docker)
Run the following commands in your terminal to spin up the official Ollama container and download the optimized coding model:

```bash
# Start the Ollama container in the background
docker run -d -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama

# Download and run Qwen2.5-Coder
docker exec -it ollama ollama run qwen2.5-coder:3b
```

### 2. Python Environment Setup
Open your terminal inside the project folder (`musescore_ollama_client/`) and run:

```bash
# Create a virtual environment
python3 -m venv venv

# Activate the virtual environment
source venv/bin/activate  # On Windows use: .\venv\Scripts\Activate.ps1

# Install required dependencies
pip install httpx
```

### 3. MuseScore 4 Plugin Setup
1. Locate the `.qml` plugin file inside the `plugin-musescore/` folder.
2. Copy it into your MuseScore Plugins directory:
   * **Linux:** `~/Documents/MuseScore4/Plugins/`
   * **macOS:** `/Users/YOUR_USERNAME/Documents/MuseScore4/Plugins/`
   * **Windows:** `C:\Users\YOUR_USERNAME\Documents\MuseScore4\Plugins\`
3. Open **MuseScore 4**, go to **Home ➔ Plugins**, and check the box to **Enable** the plugin.
4. ⚠️ **Important:** Every time you open a sheet music file you want to work on, go to the top **Plugins** menu and click on the plugin name to initialize the HTTP server.

---

## 💻 How to Use

1. Ensure your Ollama Docker container is up and running.
2. Open your score in MuseScore and activate the plugin from the menu.
3. Launch the Python bridge script:
   ```bash
   python3 ollama_bridge.py
   ```
4. Type your natural language commands directly into the terminal prompt. 

### 💡 Example Commands (Italian)
* `"Inserisci una nota croma con pitch 60 nella battuta 0"`
* `"Cancella le prime 2 battute"`
* `"Adatta il rigo 0 per basso a 4 corde"` *(Triggers the intelligent transposition algorithm for notes below low E/MIDI 28).*

---

## 📜 Credits & License

* **Original Work:** This project includes a modified version of the QML plugin structure based on [ghchen99/mcp-musescore](https://github.com/ghchen99/mcp-musescore).
* **License:** Distributed under the **MIT License**. See the `LICENSE` file for more information.

---
<p align="center">Made with ❤️ for smart musical notation</p>