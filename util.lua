local util = {}

function util.distance(s, e)
	local dx = s.x - e.x
	local dy = s.y - e.y
	return math.sqrt(dx * dx + dy * dy)
end

return util
