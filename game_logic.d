import core.bitop;

import std.algorithm.comparison;

import ae.utils.mapset;
import ae.utils.mapset.vars;
import ae.utils.meta;

import common;

alias StateSet = MapSet!(VarName, VarValue);
alias Visitor = MapSetVisitor!(VarName, VarValue);
alias Vars = MapSetVars!(VarName, VarValue);

enum Action : ubyte
{
	right,
	up,
	left,
	down,

	switchCharacter,
}

enum performImpossible = -1;
enum performComplete   = -2;

enum delayMove         =  9; // 1+8
enum delayPush         = 10; // 2+8
enum delayFill         = 26;
enum delayRotate       = 12;
enum delaySwitch       = 30;
enum delaySwitchAgain  = 32;
enum delayExit         =  1; // fake delay to prevent grouping into one frame group

int perform(ref const Level level, ref Vars v, Action action)
{
	final switch (action)
	{
		// case Action.none:
		// 	assert(false);

		case Action.switchCharacter:
			if (level.numCharacters == 1)
				return performImpossible;
			else
			{
				auto c0coord_ = v[level.varNameCharacterCoord[0]];
				auto c0coord = c0coord_;

				ubyte c = 1;
				for (; c <= level.numCharacters; c++)
				{
					if (c == level.numCharacters)
						break;

					auto ccCoord = v[level.varNameCharacterCoord[c]];
					auto isPresent = !!ccCoord.map(v => v != 0).resolve();
					if (!isPresent)
						break;

					v[level.varNameCharacterCoord[c - 1]] = ccCoord;
				}

				if (c == 1)
					return performImpossible; // Just one character left, no one to switch to.

				v[level.varNameCharacterCoord[c - 1]] = c0coord;

				bool justSwitched;
				if (level.numCharacters == 2)
				{
					// We can assume the solver will never want to
					// switch back to the same character immediately
					justSwitched = false;
				}
				else
				{
					justSwitched = !!v[level.varNameJustSwitched].resolve();
					v[level.varNameJustSwitched] = true;
				}

				return justSwitched ? delaySwitchAgain : delaySwitch;
			}

		case Action.right:
		case Action.up:
		case Action.left:
		case Action.down:
			if (level.numCharacters > 2)
				v[level.varNameJustSwitched] = false;

			auto p = level.decode!CharacterCoord(v[level.varNameCharacterCoord[0]].resolve());
			assert(p.x > 0 && p.x + 1 < level.w && p.y > 0 && p.y + 1 < level.h);

			auto n = p;
			const d = cast(Direction)((action - Action.right) + Direction.right);
			n.x += dirX[d];
			n.y += dirY[d];

			auto tile = level.map[n.y][n.x];
			final switch (tile)
			{
				case Tile.exit:
					v[level.varNameCell[p.y][p.x]] = level.encode(Cell(Cell.Type.empty));

					ubyte c = 1;
					for (; c <= level.numCharacters; c++)
					{
						if (c == level.numCharacters)
							break;

						auto ccCoord = v[level.varNameCharacterCoord[c]];
						auto isPresent = !!ccCoord.map(v => v != 0).resolve();
						if (!isPresent)
							break;

						v[level.varNameCharacterCoord[c - 1]] = ccCoord;
					}

					v[level.varNameCharacterCoord[c - 1]] = level.encode(CharacterCoord.init);

					if (c == 1)
					{
						dump(level, v.visitor);
						return performComplete;
						//return delayMove + delayExit;
					}

					return delayMove + delaySwitch;

				case Tile.wall:
				case Tile.turnstileCenter:
					return performImpossible;

				case Tile.free:
					const cell = level.decode!Cell(v[level.varNameCell[n.y][n.x]].resolve());

					// If there is a hole, we cannot step into it,
					// no matter what else is here.
					if (cell.hole)
						return performImpossible;

					final switch (cell.type)
					{
						case Cell.Type.empty:
							v[level.varNameCharacterCoord[0]] = level.encode(n);
							v[level.varNameCell[p.y][p.x]] = level.encode(Cell(Cell.Type.empty));
							v[level.varNameCell[n.y][n.x]] = level.encode(Cell(Cell.Type.character));
							return delayMove;

						case Cell.Type.block:
							// Original block coords
							auto ox0 = n.x - cell.block.x;
							auto oy0 = n.y - cell.block.y;
							auto ox1 = ox0 + cell.block.w;
							auto oy1 = oy0 + cell.block.h;

							// New block coords
							auto nx0 = ox0 + dirX[d];
							auto ny0 = oy0 + dirY[d];
							auto nx1 = ox1 + dirX[d];
							auto ny1 = oy1 + dirY[d];

							// Pushable in theory?
							foreach (y; ny0 .. ny1)
								foreach (x; nx0 .. nx1)
								{
									auto inOld = x >= ox0 && x < ox1 && y >= oy0 && y < oy1;
									if (!inOld) // in new but not old, i.e. the area that will be newly occupied
										final switch (level.map[y][x])
										{
											case Tile.free:
												continue;
											case Tile.wall:
											case Tile.turnstileCenter:
											case Tile.exit:
												return performImpossible;
										}
								}

							// Pushable in practice?
							foreach (y; ny0 .. ny1)
								foreach (x; nx0 .. nx1)
								{
									auto inOld = x >= ox0 && x < ox1 && y >= oy0 && y < oy1;
									if (!inOld) // in new but not old, i.e. the area that will be newly occupied
									{
										auto ok = v[level.varNameCell[y][x]].map((v) {
											auto c = level.decode!Cell(v);
											final switch (c.type)
											{
												case Cell.Type.empty:
													return true; // regardless of hole
												case Cell.Type.block:
												case Cell.Type.turnstile:
												case Cell.Type.character:
													return false;
											}
										}).resolve();
										if (!ok)
											return performImpossible;
									}
								}

							// Fillable in theory?
							auto fillable = {
								foreach (y; ny0 .. ny1)
									foreach (x; nx0 .. nx1)
										if (!level.decode!Cell(level.initialState[level.varNameCell[y][x]]).hole)
										{
											// There was never, and thus can never be, a hole here.
											return false;
										}
								return true;
							}();

							// Fillable in practice?
							fillable = fillable && {
								foreach (y; ny0 .. ny1)
									foreach (x; nx0 .. nx1)
										if (!level.decode!Cell(v[level.varNameCell[y][x]].resolve()).hole)
										{
											// There was a hole here once, but not right now.
											return false;
										}
								return true;
							}();

							foreach (y; min(oy0, ny0) .. max(oy1, ny1))
								foreach (x; min(ox0, nx0) .. max(ox1, nx1))
								{
									auto inOld = x >= ox0 && x < ox1 && y >= oy0 && y < oy1;
									auto inNew = x >= nx0 && x < nx1 && y >= ny0 && y < ny1;
									auto c = level.decode!Cell(v[level.varNameCell[y][x]].resolve());
									if (inOld)
										assert(c.type == Cell.Type.block);
									if (inNew)
									{
										if (fillable)
										{
											// Fill it - clear type and hole
											c.type = Cell.Type.empty;
											c.empty = Cell.Empty.init; // Clear vestigial state
											assert(c.hole);
											c.hole = false;
										}
										else
										{
											// Just move it
											c.type = Cell.Type.block;
											c.block.w = cell.block.w;
											c.block.h = cell.block.h;
											c.block.x = cast(ubyte)(x - nx0);
											c.block.y = cast(ubyte)(y - ny0);
										}
									}	
									else
									if (inOld)
									{
										// Clear only type (leaving hole)
										c.type = Cell.Type.empty;
										c.empty = Cell.Empty.init; // Clear vestigial state
									}
									v[level.varNameCell[y][x]] = level.encode(c);
								}

							// The way forward is now clear.
							v[level.varNameCharacterCoord[0]] = level.encode(n);
							v[level.varNameCell[p.y][p.x]] = level.encode(Cell(Cell.Type.empty));
							v[level.varNameCell[n.y][n.x]] = level.encode(Cell(Cell.Type.character));
							return delayPush;

						case Cell.Type.turnstile:
							auto ourWingDir = cell.turnstile.thisDirection;
							auto cx = n.x + dirX[ourWingDir.opposite];
							auto cy = n.y + dirY[ourWingDir.opposite];

							byte spin;
							final switch ((d - ourWingDir + enumLength!Direction) % enumLength!Direction)
							{
								case 0:
									// Impossible, we would need to be on top of the turnstile center.
									assert(false);
								case 1:
									// Counterclockwise
									spin = 1;
									break;
								case 2:
									// We're walking into it head-on.
									return performImpossible;
								case 3:
									// Clockwise
									spin = -1;
									break;
							}

							// Pushable in theory?
							foreach (wingDir; Direction.init .. enumLength!Direction)
								if (cell.turnstile.haveDirection & (1 << wingDir))
								{
									auto rotDir = wingDir;
									// Start with the wing's coordinate.
									auto x = cx + dirX[rotDir];
									auto y = cy + dirY[rotDir];

									// Twice go in the direction we're spinning.
									// First iteration will be checking the corner (45 degree rotation).
									// Second iteration is the wing's final position (90 degree rotation).
									foreach (i; 0 .. 2)
									{
										rotDir += spin;
										rotDir %= enumLength!Direction;
										x += dirX[rotDir];
										y += dirY[rotDir];
										final switch (level.map[y][x])
										{
											case Tile.free:
												continue;
											case Tile.wall:
											case Tile.turnstileCenter:
											case Tile.exit:
												return performImpossible;
										}
									}
								}

							// Pushable in practice?
							foreach (wingDir; Direction.init .. enumLength!Direction)
								if (cell.turnstile.haveDirection & (1 << wingDir))
								{
									auto rotDir = wingDir;
									// Start with the wing's coordinate.
									auto x = cx + dirX[rotDir];
									auto y = cy + dirY[rotDir];

									// As above.
									foreach (i; 0 .. 2)
									{
										rotDir += spin;
										rotDir %= enumLength!Direction;
										x += dirX[rotDir];
										y += dirY[rotDir];
										auto ok = {
											if (x == p.x && y == p.y)
											{
												assert(i == 0); // corner
												return true; // ignore our character
											}

											if (i == 1)
											{
												auto relDir = (wingDir + spin + enumLength!Direction) % enumLength!Direction;
												if (cell.turnstile.haveDirection & (1 << relDir))
												{
													// Our wing is there right now. Therefore, nothing else can be.
													debug
													{
														auto c = level.decode!Cell(v[level.varNameCell[y][x]].resolve());
														assert(c.type == Cell.Type.turnstile
															&& c.turnstile.thisDirection == relDir
															&& c.turnstile.haveDirection == cell.turnstile.haveDirection);
													}
													return true;
												}
											}

											return v[level.varNameCell[y][x]].map((v) {
												auto c = level.decode!Cell(v);
												final switch (c.type)
												{
													case Cell.Type.empty:
														return true; // regardless of hole
													case Cell.Type.block:
													case Cell.Type.character:
														return false;
													case Cell.Type.turnstile:
														auto otherWingDir = c.turnstile.thisDirection;
														auto cx2 = x + dirX[otherWingDir.opposite];
														auto cy2 = y + dirY[otherWingDir.opposite];
														if (cx2 == cx && cy2 == cy)
															assert(false); // It's us. Impossible.
														return false; // Another turnstile.
												}
											}).resolve();
										}();
										if (!ok)
											return performImpossible;
									}
								}

							// How many tiles will the character move forward?
							{
								auto prevWingDir = d.opposite;
								if (cell.turnstile.haveDirection & (1 << prevWingDir))
								{
									n.x += dirX[d];
									n.y += dirY[d];
									auto targetCell = level.decode!Cell(v[level.varNameCell[n.y][n.x]].resolve());
									assert(targetCell.type == Cell.Type.empty);
									if (targetCell.hole)
										return performImpossible;
								}
							}

							// Rotate it.
							if (cell.turnstile.haveDirection == 0b1111)
							{
								// Plus-turnstile. No update necessary.
							}
							else
							{
								ubyte newHaveDirection;
								foreach (targetDir; Direction.init .. enumLength!Direction)
								{
									auto sourceDir = (targetDir - spin + enumLength!Direction) % enumLength!Direction;
									if (cell.turnstile.haveDirection & (1 << sourceDir))
										newHaveDirection |= 1 << targetDir;
								}
								assert(cell.turnstile.haveDirection.popcnt == newHaveDirection.popcnt);

								foreach (targetDir; Direction.init .. enumLength!Direction)
								{
									auto sourceDir = (targetDir - spin + enumLength!Direction) % enumLength!Direction;
									auto x = cx + dirX[targetDir];
									auto y = cy + dirY[targetDir];
									if (level.map[y][x] == Tile.free)
									{
										auto c = level.decode!Cell(v[level.varNameCell[y][x]].resolve());

										// Sanity check - there was a wing here iff it's in our flags.
										assert(
											!!(cell.turnstile.haveDirection & (1 << targetDir))
											==
											(c.type == Cell.Type.turnstile
												&& c.turnstile.thisDirection == targetDir)
										);

										if (cell.turnstile.haveDirection & (1 << sourceDir))
										{
											// A wing will be here. Configure it, regardless if a wing *was* here.
											c.type = Cell.Type.turnstile;
											c.turnstile.thisDirection = targetDir;
											c.turnstile.haveDirection = newHaveDirection;
										}
										else
										if (cell.turnstile.haveDirection & (1 << targetDir))
										{
											// A wing was here, and now won't. Clear it.
											c.type = Cell.Type.empty;
											c.empty = Cell.Empty.init; // Clear vestigial state
										}
										v[level.varNameCell[y][x]] = level.encode(c);
									}
									else
									{
										assert(!(cell.turnstile.haveDirection & (1 << sourceDir)));
									}
								}
							}

							// Move the character.
							v[level.varNameCharacterCoord[0]] = level.encode(n);
							v[level.varNameCell[p.y][p.x]] = level.encode(Cell(Cell.Type.empty));
							v[level.varNameCell[n.y][n.x]] = level.encode(Cell(Cell.Type.character));
							return delayRotate;

						case Cell.Type.character:
							return performImpossible;
					}
			}
	}
}

void dump(ref const Level level, ref Visitor v)
{
	import std.stdio : write, writeln;

	foreach (y; 0 .. level.h)
	{
		foreach (x; 0 .. level.w)
			final switch (level.map[y][x])
			{
				case Tile.exit:
					write('%');
					break;

				case Tile.wall:
					write('#');
					break;

				case Tile.turnstileCenter:
					write('*');
					break;

				case Tile.free:
					auto cell = level.decode!Cell(v.get(level.varNameCell[y][x]));
					final switch (cell.type)
					{
						case Cell.Type.empty:
							if (cell.hole)
								write('O');
							else
								write(' ');
							break;

						case Cell.Type.block:
							write(cast(char)('a' + ((x - cell.block.x) + (y - cell.block.y)) % 26));
							break;

						case Cell.Type.turnstile:
							write(">^<`"[cell.turnstile.thisDirection]);
							break;

						case Cell.Type.character:
							char c = '?';
							foreach (i; 0 .. level.numCharacters)
							{
								auto coord = level.decode!CharacterCoord(v.get(level.varNameCharacterCoord[i]));
								if (coord.x == x && coord.y == y)
									c = cast(char)('1' + i);
							}
							write(c);
							break;
					}
			}
		writeln;
	}
}
