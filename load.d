import ae.utils.meta;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.exception;
import std.file;
import std.string;
import std.stdio;
import std.sumtype;
import std.typecons;

import common;

Level loadLevel(string fileName)
{
	Level level;

	string[] levelLines;
	foreach (line; splitLines(readText(fileName)))
	{
		if (line.length==0)
			continue;
		else
		if (line.skipOver("MAX_FRAMES "))
			continue; // ignore
		else
		if (line.skipOver("MAX_STEPS "))
			continue; // ignore
		else
		if (line == "HAVE_VALIDATOR")
			continue; // ignore
		else
		if (line[0]=='#')
		{
			if (levelLines.length && levelLines[0].length != line.length)
				throw new Exception("Uneven level width");
			levelLines ~= line;
		}
		else
			throw new Exception("Unknown level line: " ~ line);
	}

	level.w = levelLines[0].length;
	level.h = levelLines.length;

	// non-null cells are also walkable (i.e. representable in characterCoord coordinates)
	auto cells = new Nullable!Cell[][](level.h, level.w);
	CharacterCoord[int] characterStartingCoordinates;
	bool[maxBlockSize][maxBlockSize] haveBlockSize;
	bool[ubyte] haveTurnstile;
	bool haveHoles;

	// Collection

	foreach (y, line; levelLines)
		foreach (x, c; line)
			switch (c)
			{
				// Empty
				case ' ':
					level.map[y][x] = Tile.free;
					Cell cell;
					cell.type = Cell.Type.empty;
					cells[y][x] = cell;
					break;

				// Wall
				case '#':
				case '+':
					level.map[y][x] = Tile.wall;
					break;

				// Exit
				case '%':
					level.map[y][x] = Tile.exit;
					break;

				// Hole
				case 'O':
					level.map[y][x] = Tile.free;
					haveHoles = true;

					Cell cell;
					cell.type = Cell.Type.empty;
					cell.hole = true;
					cells[y][x] = cell;
					break;

				// Character starting position
				case '1':
					..
				case '4':
					level.map[y][x] = Tile.free;
					auto characterIndex = c - '1';

					Cell cell;
					cell.type = Cell.Type.character;
					cells[y][x] = cell;

					enforce(characterIndex !in characterStartingCoordinates, "Duplicate character");
					characterStartingCoordinates[characterIndex] = CharacterCoord(x.to!ubyte, y.to!ubyte);

					level.numCharacters = cast(ubyte)max(level.numCharacters, characterIndex + 1);
					break;

				// Block
				case 'a':
					..
				case 'z':
					auto xMin = x, yMin = y, xMax = x, yMax = y;
					while (levelLines[y][xMin - 1] == c) xMin--;
					while (levelLines[y][xMax + 1] == c) xMax++;
					while (levelLines[yMin - 1][x] == c) yMin--;
					while (levelLines[yMax + 1][x] == c) yMax++;
					auto bw = xMax - xMin + 1;
					auto bh = yMax - yMin + 1;

					Cell cell;
					cell.type = Cell.Type.block;
					cell.block.w = bw.to!ubyte;
					cell.block.h = bh.to!ubyte;
					cell.block.x = (x - xMin).to!ubyte;
					cell.block.y = (y - yMin).to!ubyte;
					cells[y][x] = cell;

					haveBlockSize[bh][bw] = true;
					break;

				// Turnstile center
				case '*':
					level.map[y][x] = Tile.turnstileCenter;
					break;

				// Turnstile
				case '>':
				case '^':
				case '<':
				case '`':
					static immutable turnstileWingChars = ">^<`";
					auto d = cast(Direction) turnstileWingChars.indexOf(c);
					auto cx = x + dirX[d.opposite];
					auto cy = y + dirY[d.opposite];
					enforce(levelLines[cy][cx] == '*', "Turnstile wing not attached to center");

					Cell cell;
					cell.type = Cell.Type.turnstile;
					cell.turnstile.thisDirection = d;
					foreach (wd; Direction.init .. enumLength!Direction)
						if (levelLines[cy + dirY[wd]][cx + dirX[wd]] == turnstileWingChars[wd])
							cell.turnstile.haveDirection |= (1 << wd);
					cells[y][x] = cell;

					auto rotated = cell.turnstile.haveDirection;
					foreach (rd; Direction.init .. enumLength!Direction)
					{
						haveTurnstile[rotated] = true;
						rotated = ((rotated << 1) & 0b1111) | (rotated >> 3);
					}
					break;

				default:
					throw new Exception(format("Unknown character in level: %s", c));
			}

	// Compilation

	auto nullCoord = level.register(CharacterCoord.init);
	assert(nullCoord == 0);

	foreach (y; 0 .. level.h)
		foreach (x; 0 .. level.w)
			if (!cells[y][x].isNull)
				level.register(CharacterCoord(x.to!ubyte, y.to!ubyte));

	foreach (character; 0 .. level.numCharacters)
		level.initialState[varNameCharacterCoord(character)] = level.encode(characterStartingCoordinates[character]);

	auto holes = haveHoles ? [false, true] : [false];

	foreach (hole; holes)
	{
		Cell cell;
		cell.type = Cell.Type.empty;
		cell.hole = hole;
		level.register(cell);
	}

	foreach (hole; holes)
		foreach (ubyte h; 0 .. maxBlockSize)
			foreach (ubyte w; 0 .. maxBlockSize)
				if (haveBlockSize[h][w])
					foreach (ubyte y; 0 .. h)
						foreach (ubyte x; 0 .. w)
						{
							Cell cell;
							cell.type = Cell.Type.block;
							cell.block.w = w;
							cell.block.h = h;
							cell.block.x = x;
							cell.block.y = y;
							cell.hole = hole;
							level.register(cell);
						}

	foreach (hole; holes)
		foreach (ubyte haveDirectionFlags; 0 .. 1 << enumLength!Direction)
			foreach (wingDirection; Direction.init .. enumLength!Direction)
				if (haveDirectionFlags & (1 << wingDirection))
				{
					Cell cell;
					cell.type = Cell.Type.turnstile;
					cell.turnstile.haveDirection = haveDirectionFlags;
					cell.turnstile.thisDirection = wingDirection;
					cell.hole = hole;
					level.register(cell);
				}

	{
		Cell cell;
		cell.type = Cell.Type.character;
		level.register(cell);
	}

	// Application

	foreach (y; 0 .. level.h)
		foreach (x; 0 .. level.w)
			if (!cells[y][x].isNull)
				level.initialState[varNameCell(x, y)] = level.encode(cells[y][x].get());

	// Validation

	foreach (y; 0 .. level.h)
		foreach (x; 0 .. level.w)
			switch (level.map[y][x])
			{
				case Tile.wall:
					enforce(level.initialState[varNameCell(x, y)] == invalidVarValue);
					break;

				case Tile.turnstileCenter:
					enforce(level.initialState[varNameCell(x, y)] == invalidVarValue);

					auto numWings = 0;
					foreach (d; Direction.init .. enumLength!Direction)
					{
						auto dx = x + dirX[d];
						auto dy = y + dirY[d];
						if (level.map[dy][dx] == Tile.free)
						{
							auto dTile = level.decode!Cell(level.initialState[varNameCell(dx, dy)]);
							if (dTile.type == Cell.Type.turnstile && dTile.turnstile.thisDirection == d)
								numWings++;
						}
					}
					enforce(numWings > 0, "Turnstile center without wings");
					break;

				default:
					break;
			}

	return level;
}
