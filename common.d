module common;

import std.bitmanip;
import std.conv : to;
import std.traits;

import ae.utils.meta : enumLength;

enum maxCharacters = 4;
enum maxWidth = 32;
enum maxHeight = 32;
enum maxBlockSize = 16; // actually 11 but this makes the math easier

enum Direction : ubyte
{
	right,
	up,
	left,
	down,
}

Direction opposite(Direction d) { return cast(Direction)((d + 2) % 4); }

immutable byte[enumLength!Direction] dirX = [1, 0, -1, 0];
immutable byte[enumLength!Direction] dirY = [0, -1, 0, 1];

enum VarName : ubyte
{
	first = 0,
	invalid = 0xFF,

	tempVarStart = 0xF0,
	tempVarEnd = 0xFF,
	length = tempVarEnd,
}

enum invalidVarName = VarName.invalid;

alias VarValue = ubyte;

enum invalidVarValue = VarValue.max;

struct CharacterCoord
{
	ubyte x, y;
}

struct Cell
{
	enum Type : ubyte
	{
		empty,
		block,
		turnstile,
		character,
	}
	Type type;

	union
	{
		struct Empty { ubyte[2] padding; }
		Empty empty;

		struct Block
		{
			mixin(bitfields!(
				// The total width and height of the entire block.
				ubyte, "w",  4,
				ubyte, "h",  4,
				// The coordinates within the block that are on this tile.
				ubyte, "x",  4,
				ubyte, "y",  4,
			));
		}
		Block block;

		struct Turnstile
		{
			ubyte haveDirection; /// bitfield over Direction
			Direction thisDirection; /// direction of the piece in this tile; opposite direction is the turnstile center
		}
		Turnstile turnstile;
	}

	bool hole;
}

enum Tile : ubyte
{
	free, /// empty, block, hole, or character, etc. - consult the current state to see what's here
	wall, /// cannot be interacted with
	turnstileCenter,
	exit,
}

/// Constants.
struct Level
{
	size_t w, h;
	Tile[maxWidth][maxHeight] map;

	ubyte numCharacters;

	// ---

	VarName varNameJustSwitched = invalidVarName;

	VarName[maxCharacters] varNameCharacterCoord = invalidVarName;
	VarName[maxHeight][maxWidth] varNameCell = invalidVarName;

	size_t numVars = 0;
	VarName registerVariable()
	{
		auto n = cast(VarName)(numVars++).to!(OriginalType!VarName);
		assert(n < VarName.tempVarStart, "Too many variables");
		return n;
	}

	// ---

	VarValue[/*varNameCard*/] initialState;

	// ---

	T decode(T)(VarValue v) const
	{
		assert(v != invalidVarValue, "Invalid variable value");
		return valuesFor!T[v];
	}

	VarValue encode(T)(T v) const
	{
		auto vv = getSlot(v);
		assert(vv != invalidVarValue, "Unrepresentable value");
		return vv;
	}

	VarValue register(T)(T v)
	{
		VarValue vv = valuesFor!T.length.to!VarValue;
		valuesFor!T ~= v;
		auto slot = &getSlot(v);
		assert(*slot == invalidVarValue, "Duplicate VarValue");
		*slot = vv;
		return vv;
	}

	// ---

	CharacterCoord[/*VarValue*/] characterCoordValues;
	VarValue[maxWidth][maxHeight] characterCoordLookup = invalidVarValue;

	ref inout(T[]) valuesFor(T)() inout
	if (is(T == CharacterCoord))
	{ return characterCoordValues; }

	ref inout(VarValue) getSlot(CharacterCoord v) inout
	{ return characterCoordLookup[v.y][v.x]; }

	// ---

	Cell[/*VarValue*/] cellValues;
	VarValue[2] cellEmptyLookup = invalidVarValue;
	VarValue[maxBlockSize][maxBlockSize][maxBlockSize][maxBlockSize][2] cellBlockLookup = invalidVarValue;
	VarValue[enumLength!Direction][1 << enumLength!Direction][2] cellTurnstileLookup = invalidVarValue;
	VarValue cellCharacterLookup = invalidVarValue;

	ref inout(T[]) valuesFor(T)() inout
	if (is(T == Cell))
	{ return cellValues; }

	ref inout(VarValue) getSlot(Cell v) inout @nogc
	{
		final switch (v.type)
		{
			case Cell.Type.empty: return cellEmptyLookup[v.hole];
			case Cell.Type.block: return cellBlockLookup[v.hole][v.block.w][v.block.h][v.block.x][v.block.y];
			case Cell.Type.turnstile: return cellTurnstileLookup[v.hole][v.turnstile.haveDirection][v.turnstile.thisDirection];
			case Cell.Type.character: assert(!v.hole); return cellCharacterLookup;
		}
	}
}
