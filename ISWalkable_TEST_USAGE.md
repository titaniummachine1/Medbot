# ISWalkable Test Suite Usage

## Overview

The ISWalkable Test Suite is a standalone testing module that mimics the visual toggle system from `A_standstillDummy.lua`. It allows you to test and optimize the ISWalkable function without breaking any existing MedBot functionality.

## Features

- **Menu Integration**: Toggle via MedBot menu (Visuals tab → ISWalkable Test)
- **Visual Feedback**: See walkability results with colored arrows (green = walkable, red = not walkable)
- **Benchmark Data**: Real-time memory and performance metrics
- **Debug Visualization**: See hull traces and line traces used by ISWalkable
- **Position Saving**: Save your current position as the target destination
- **Non-Intrusive**: Doesn't interfere with normal bot operation when disabled

## Controls

- **Enable/Disable**: Open MedBot menu → Visuals tab → Check "ISWalkable Test"
- **Set Target Position**: Hold **SHIFT** to set your current position as the target
- **Movement**: The test only runs when you're not moving (forward/side move = 0)

## Menu Location

1. Open Lmaobox menu
2. Go to **MedBot Control** tab
3. Select **Visuals** tab
4. Find **ISWalkable Test** section at the bottom
5. Check the **ISWalkable Test** checkbox to enable

## Visual Indicators

- **White Box**: Target position (where you want to walk)
- **Green Arrow**: Path is walkable
- **Red Arrow**: Path is not walkable
- **Blue Arrows**: Hull traces used in ISWalkable calculation
- **White Lines**: Line traces used in ISWalkable calculation

## On-Screen Information

- Test status (ON/OFF)
- Memory usage (KB)
- Time usage (ms)
- Walkability result (WALKABLE/NOT WALKABLE)
- Instructions for SHIFT key

## Usage Example

1. Load MedBot with the test suite (automatically loaded)
2. Open Lmaobox menu → MedBot Control → Visuals tab
3. Enable "ISWalkable Test" checkbox
4. Move to a position where you want to test walkability from
5. Hold SHIFT to set that position as the target
6. Move to another position and stop moving
7. The test will automatically run and show results
8. Disable by unchecking the checkbox when done

## Integration

- **File**: `MedBot/Bot/ISWalkableTest.lua`
- **Auto-loaded**: Required by `Main.lua`
- **Menu Integration**: Available in Visuals tab
- **Global Access**: Available via `G.ISWalkableTest`
- **Independent**: Runs alongside normal MedBot without interference

## Performance

- Uses the same optimized ISWalkable algorithm from your dummy file
- Benchmarks each test run with memory and timing data
- Maintains rolling average of last 66 test results
- Only runs when stationary to avoid interference

## Safety

- **Black Box Compliant**: Isolated module with single responsibility
- **Non-Breaking**: Doesn't modify existing MedBot functionality
- **Self-Contained**: All dependencies are self-managed
- **Menu-Controlled**: Can be completely disabled via menu

## Troubleshooting

- **No visuals showing**: Make sure "ISWalkable Test" is enabled in the Visuals tab
- **No menu option**: Reload MedBot to ensure the test module is loaded
- **Visuals disappear**: Check that you're not in console or game UI
- **No test running**: Make sure you're standing still (no movement input)
