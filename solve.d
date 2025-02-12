import std.format;
import std.stdio : stderr, File;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;

import common;
import game_logic;
import load;

void program(
	string levelFileName,
)
{
	auto level = loadLevel(levelFileName);

	StateSet initialSet = StateSet.unitSet;
	foreach (name, VarValue value; level.initialState)
		initialSet = initialSet.set(cast(VarName)name, value);

	StateSet[] statesAtFrame = [initialSet];
	StateSet seenStates;

	auto trace = File(levelFileName ~ ".trace", "wb");

	for (uint frameNumber = 0; ; frameNumber++)
	{
		assert(frameNumber < statesAtFrame.length, "No more states.");
		auto set = statesAtFrame[frameNumber];

		stderr.writefln("Frame %d: %d states, %d nodes",
			frameNumber,
			set.count,
			set.uniqueNodes,
		);

		set = set.subtract(seenStates);
		stderr.writefln("  Deduplicated: %d states, %d nodes", set.count, set.uniqueNodes);
		set = set.optimize();
		stderr.writefln("  Optimized: %d nodes", set.uniqueNodes);

		seenStates = seenStates.merge(set);
		stderr.writefln("  Total: %d states, %d nodes", seenStates.count, seenStates.uniqueNodes);
		seenStates = seenStates.optimize();
		stderr.writefln("    Optimized: %d nodes", seenStates.uniqueNodes);

		trace.writefln("%d\t%d\t%d", frameNumber, seenStates.count, seenStates.uniqueNodes); trace.flush();

		foreach (action; Action.init .. enumLength!Action)
		{
			Vars v;
			v.visitor = Visitor(set);

			ulong numIterations;
			while (v.next())
			{
				numIterations++;
				auto duration = perform(level, v, action);
				if (duration == performImpossible)
					continue;
				if (duration == performComplete)
					return;
				auto nextFrame = frameNumber + duration;
				if (statesAtFrame.length < nextFrame + 1)
					statesAtFrame.length = nextFrame + 1;
				statesAtFrame[nextFrame] = statesAtFrame[nextFrame].merge(v.visitor.currentSubset);
			}
			stderr.writefln("  Processed %s in %d iterations.", action, numIterations);
		}
	}
}

mixin main!(funopt!program);
