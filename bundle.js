import { bundle } from 'luabundle'
import * as fs from 'fs';

// Set timeout to force exit if hanging
const timeout = setTimeout(() => {
    console.error('Bundle process timeout after 5 seconds - forcing exit');
    process.exit(1);
}, 5000);

// Wrap everything in an async function to handle the bundling process properly
async function runBundle() {
    try {
        console.log('Starting Lua bundle process...');
        
        const bundledLua = bundle('./MedBot/Main.lua', {
            metadata: false,
            expressionHandler: (module, expression) => {
                const start = expression.loc.start
                console.warn(`WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`)
            }
        });

        console.log('Bundle generation completed, writing to file...');

        // Use synchronous writeFile to avoid async hanging
        fs.writeFileSync('MedBot.lua', bundledLua);
        
        clearTimeout(timeout);
        console.log('Library bundle created successfully');
        process.exit(0);
        
    } catch (error) {
        clearTimeout(timeout);
        console.error('Bundle failed:', error.message);
        if (error && error.cause) {
            try {
                console.error('Cause message:', error.cause.message || String(error.cause));
                if (error.cause.stack) console.error('Cause stack:', error.cause.stack);
            } catch (_) {}
        }
        console.error('Stack:', error.stack);
        process.exit(1);
    }
}

runBundle();