const { Atem } = require('atem-connection');

// --- CONFIGURATION ---
const ATEM_IP = '10.1.0.40'; 
// ---------------------

const myAtem = new Atem();

console.log('------------------------------------------------');
console.log('📡  ATEM DIAGNOSTIC SNIFFER');
console.log(`🎯  Target IP: ${ATEM_IP}`);
console.log('------------------------------------------------');
console.log('Connecting...');

myAtem.on('connected', () => {
    console.log('\n✅  CONNECTED!');
    console.log('👉  Press any button on your ATEM to see its "Path Name".');
    console.log('❌  Press Ctrl+C to stop.\n');
});

myAtem.on('stateChanged', (state, paths) => {
    
    // 1. FILTER OUT NOISE
    // These events fire constantly (every second or frame). 
    // We filter them out so they don't flood your screen.
    const cleanPaths = paths.filter(path => {
        return !path.includes('duration') &&   // Hides recording timer ticks
               !path.includes('timecode') &&   // Hides internal clock ticks
               !path.includes('levels');       // Hides audio level bouncing
    });

    // 2. PRINT ONLY IF THERE IS SOMETHING LEFT
    if (cleanPaths.length > 0) {
        console.log('⚡ Action Detected:', cleanPaths);
    }
});

myAtem.on('disconnected', () => {
    console.log('⚠️  Disconnected...');
});

// Handle graceful exit
process.on('SIGINT', () => {
    console.log('\n👋  Closing connection and exiting...');
    myAtem.disconnect();
    process.exit();
});

myAtem.connect(ATEM_IP);
