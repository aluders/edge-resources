const { Atem } = require('atem-connection');
const { exec } = require('child_process');

// --- CONFIGURATION ---
const ATEM_IP = '10.1.0.40';
const SCRIPT_TO_RUN = '/home/edgeadmin/atem-download.sh';
// ---------------------

const myAtem = new Atem();
let wasRecording = false;

myAtem.on('connected', () => {
    console.log(`✅ Connected to ATEM at ${ATEM_IP}`);
    
    // Check initial state
    const state = myAtem.state;
    if (state && state.recording && state.recording.status) {
        // 1 = Recording, 0 = Idle
        wasRecording = state.recording.status.state === 1; 
        console.log(`ℹ️  Initial State: ${wasRecording ? '🔴 RECORDING' : '⬜ STOPPED'}`);
    }
});

myAtem.on('stateChanged', (state, pathToChange) => {
    // We filter for 'recording.status' because your Sniffer proved that is the exact name
    if (pathToChange.some(path => path.includes('recording.status'))) {
        
        // Read the actual status integer (1 or 0)
        const isRecording = state.recording.status.state === 1;

        // LOGIC: Only trigger if the state has ACTUALLY flipped
        if (wasRecording !== isRecording) {
            
            if (isRecording) {
                console.log('🔴 RECORDING STARTED');
            } else {
                console.log('⬜ RECORDING STOPPED -> Executing Script...');
                
                // Run the shell script
                exec(SCRIPT_TO_RUN, (error, stdout, stderr) => {
                    if (error) console.error(`Error: ${error.message}`);
                    if (stdout) console.log(`Output: ${stdout.trim()}`);
                });
            }
            
            // Update history so we don't trigger again until it changes back
            wasRecording = isRecording;
        }
    }
});

myAtem.connect(ATEM_IP);
