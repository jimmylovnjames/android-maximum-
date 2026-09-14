class_name RingBuffer
extends RefCounted
## Fixed-capacity circular float buffer used for every performance history
## graph. Avoids per-frame array reallocation.

var _data: PackedFloat32Array
var _cap: int = 0
var _head: int = 0
var _size: int = 0


func _init(capacity: int = 240) -> void:
	_cap = maxi(1, capacity)
	_data = PackedFloat32Array()
	_data.resize(_cap)


func push(v: float) -> void:
	_data[_head] = v
	_head = (_head + 1) % _cap
	if _size < _cap:
		_size += 1


func clear() -> void:
	_head = 0
	_size = 0


func size() -> int:
	return _size


func capacity() -> int:
	return _cap


func is_full() -> bool:
	return _size == _cap


## Oldest-first index access.
func get_at(i: int) -> float:
	if i < 0 or i >= _size:
		return 0.0
	var start: int = (_head - _size + _cap) % _cap
	return _data[(start + i) % _cap]


func last() -> float:
	if _size == 0:
		return 0.0
	return _data[(_head - 1 + _cap) % _cap]


## Oldest-first copy. Allocates; only call for graph drawing / result export.
func to_array() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(_size)
	var start: int = (_head - _size + _cap) % _cap
	for i in _size:
		out[i] = _data[(start + i) % _cap]
	return out


func mean() -> float:
	if _size == 0:
		return 0.0
	var s: float = 0.0
	var start: int = (_head - _size + _cap) % _cap
	for i in _size:
		s += _data[(start + i) % _cap]
	return s / float(_size)


func minimum() -> float:
	if _size == 0:
		return 0.0
	var m: float = INF
	var start: int = (_head - _size + _cap) % _cap
	for i in _size:
		m = minf(m, _data[(start + i) % _cap])
	return m


func maximum() -> float:
	if _size == 0:
		return 0.0
	var m: float = -INF
	var start: int = (_head - _size + _cap) % _cap
	for i in _size:
		m = maxf(m, _data[(start + i) % _cap])
	return m


## Value at the given percentile (0..1) of the sorted contents.
func percentile(p: float) -> float:
	if _size == 0:
		return 0.0
	var arr: PackedFloat32Array = to_array()
	var tmp: Array = Array(arr)
	tmp.sort()
	var idx: int = clampi(int(round(p * float(tmp.size() - 1))), 0, tmp.size() - 1)
	return float(tmp[idx])
