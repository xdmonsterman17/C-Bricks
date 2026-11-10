@icon("res://addons/brickscript/icons/nodes/spawn_point.svg")
class_name BrickscriptSpawnPoint
extends Marker3D

## A spawn point under a BrickscriptSpawnPoints (a Marker3D works too): it can
## be switched off, and tagged (e.g. a team) for SpawnPoints' tag_value.

## Off: no character starts here.
@export var enabled: bool = true
## Only players whose tag value (SpawnPoints.tag_value) is this start here.
## Empty: everyone.
@export var tag: String = ""
