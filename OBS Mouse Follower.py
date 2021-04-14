import obspython as obs
import time
from ctypes import windll, Structure, c_long, byref

#Configurable variables
xMaxSize = 1920
yMaxSize = 1080
zoomRate = 10
followRate = 10
keepAspectRatio = True
sourceName1 = ""
sourceName2 = ""

#Current crop
currentLeft = 0
currentTop = 0
currentRight = 0
currentBottom = 0
#Wanted crop
wantedLeft = 0
wantedTop = 0
wantedRight = 0
wantedBottom = 0
#Wanted crop when zoom disabled
wantsZoom = True
untoggledWantedLeft = 0
untoggledWantedRight = 0
untoggledWantedTop = 0
untoggledWantedBottom = 0
#Where is the camera
currentCamera = None
#Follow toggle
followingMouse = False
#For drawing the rectangle
firstPoint = [0,0]
#For undo and redo
wantedHistory = []
wantedUndos = []
#Hotkeys
hotkeyDict = {}

#Mouse C class
class POINT(Structure):
	_fields_ = [("x", c_long), ("y", c_long)]

#Get mouse position
def queryMousePosition():
	pt = POINT()
	windll.user32.GetCursorPos(byref(pt))
	return pt

#Ready
def ready():
	global hotkeyDict
	hotkeyDict = {
	"hk_t_follow":{"id":None,"description":"Toggle mouse follow","function":toggleFollow},
	"hk_undo":{"id":None,"description":"Undo rectangle set","function":undo},
	"hk_redo":{"id":None,"description":"Redo rectangle set","function":redo},
	"hk_t_zoom":{"id":None,"description":"Toggle zoom","function":toggleZoom},
	"hk_rectangle":{"id":None,"description":"Set rectangle","function":setRectangle}}


#Process
def process():
	try:
		changeSourceToMousePosition()
	except Exception as e:
		obs.timer_remove(process)
		print(e)

#Start process
obs.timer_add(process, 16)

#Current scene
def currentSceneName():
	src = obs.obs_frontend_get_current_scene()
	if src is None:
		return None
	name = obs.obs_source_get_name(src)
	obs.obs_source_release(src)
	if name is None:
		return None
	return name

#Zoom and mouse following
def changeSourceToMousePosition():
	#Get current scene
	currentScene = currentSceneName()
	if currentScene is None:
		return
	#Get scene item
	src = obs.obs_get_source_by_name(currentScene)
	if src is None:
		return
	scene = obs.obs_scene_from_source(src)
	if scene is None:
		return
	obs.obs_source_release(src)
	for sourceName in [sourceName1, sourceName2]:
		sceneItem = obs.obs_scene_find_source(scene, sourceName)
		if sceneItem is None:
			break

		#Variables
		global currentLeft
		global currentTop
		global currentRight
		global currentBottom
		global wantedLeft
		global wantedTop
		global wantedRight
		global wantedBottom

		#Following mouse
		if followingMouse:
			global currentCamera
			mousePos = queryMousePosition()
			wantedCamera = mousePos
			xSizeNow = xMaxSize - currentRight - currentLeft
			ySizeNow = yMaxSize - currentBottom - currentTop
			scaleRateFixer = ((xMaxSize + yMaxSize) / (xSizeNow + ySizeNow))
			xDiff = (wantedCamera.x - currentCamera[0]) * followRate / 100 * scaleRateFixer
			yDiff = (wantedCamera.y - currentCamera[1]) * followRate / 100 * scaleRateFixer
			#Check if already reached wanted camera
			if abs(currentCamera[0] + xDiff - wantedCamera.x) > abs(currentCamera[0] - wantedCamera.x):
				xDiff = wantedCamera.x - currentCamera[0]
			if abs(currentCamera[1] + yDiff - wantedCamera.y) > abs(currentCamera[1] - wantedCamera.y):
				yDiff = wantedCamera.y - currentCamera[1]
			#Move camera
			currentCamera[0] += xDiff
			currentCamera[1] += yDiff
			#Move crop
			wantedLeft += xDiff
			wantedRight -= xDiff
			wantedTop += yDiff
			wantedBottom -= yDiff

		#When rectangle is outside
		fixedWantedLeft = wantedLeft
		fixedWantedTop = wantedTop
		fixedWantedRight = wantedRight
		fixedWantedBottom = wantedBottom
		if fixedWantedLeft < 0:
			fixedWantedRight += fixedWantedLeft
			fixedWantedLeft = 0
		elif fixedWantedRight < 0:
			fixedWantedLeft += fixedWantedRight
			fixedWantedRight = 0
		if fixedWantedTop < 0:
			fixedWantedBottom += fixedWantedTop
			fixedWantedTop = 0
		elif fixedWantedBottom < 0:
			fixedWantedTop += fixedWantedBottom
			fixedWantedBottom = 0

		#If zoom is off
		if not wantsZoom:
			fixedWantedLeft = 0
			fixedWantedTop = 0
			fixedWantedRight = 0
			fixedWantedBottom = 0

		#Move crop
		currentLeft += (fixedWantedLeft - currentLeft) * zoomRate / 100
		currentTop += (fixedWantedTop - currentTop) * zoomRate / 100
		currentRight += (fixedWantedRight - currentRight) * zoomRate / 100
		currentBottom += (fixedWantedBottom - currentBottom) * zoomRate / 100

		#Set to OBS
		cropZone = obs.obs_sceneitem_crop()
		cropZone.left = int(round(currentLeft))
		cropZone.top = int(round(currentTop))
		cropZone.right = int(round(currentRight))
		cropZone.bottom = int(round(currentBottom))
		obs.obs_sceneitem_set_crop(sceneItem,cropZone)

#Toggle zoom
def toggleZoom(pressed):
	if not pressed:
		global wantsZoom
		wantsZoom = not wantsZoom

#Undo
def undo(pressed):
	if not pressed:
		if len(wantedHistory) == 0:
			return
		wantedOnes = wantedHistory.pop()
		global wantedLeft
		global wantedTop
		global wantedRight
		global wantedBottom
		global followingMouse
		wantedUndos.append([wantedLeft, wantedTop, wantedRight, wantedBottom])
		wantedLeft = wantedOnes[0]
		wantedTop = wantedOnes[1]
		wantedRight = wantedOnes[2]
		wantedBottom = wantedOnes[3]
		followingMouse = False

#Redo
def redo(pressed):
	if not pressed:
		if len(wantedUndos) == 0:
			return
		wantedOnes = wantedUndos.pop()
		global wantedLeft
		global wantedTop
		global wantedRight
		global wantedBottom
		global followingMouse
		wantedHistory.append([wantedLeft, wantedTop, wantedRight, wantedBottom])
		wantedLeft = wantedOnes[0]
		wantedTop = wantedOnes[1]
		wantedRight = wantedOnes[2]
		wantedBottom = wantedOnes[3]
		followingMouse = False

#Create rectangle
def setRectangle(pressed):
	mousePos = queryMousePosition()
	#On first position
	if pressed:
		global firstPoint
		firstPoint = [mousePos.x, mousePos.y]
		#Stop following mouse
		global followingMouse
		followingMouse = False
	#Ond second position
	else:
		secondPoint = [mousePos.x, mousePos.y]
		pointDistance = ((secondPoint[0]-firstPoint[0])**2 + (secondPoint[1]-firstPoint[1])**2)**0.5
		if pointDistance > 10:
			global wantedLeft
			global wantedTop
			global wantedRight
			global wantedBottom
			xx = min(firstPoint[0],secondPoint[0])
			aa = max(firstPoint[0],secondPoint[0])
			yy = min(firstPoint[1],secondPoint[1])
			bb = max(firstPoint[1],secondPoint[1])

			#Save to history
			wantedHistory.append([wantedLeft, wantedTop, wantedRight, wantedBottom])
			wantedUndos.clear()

			#Change crop
			wantedLeft = xx
			wantedTop = yy
			wantedRight = 1920 - aa
			wantedBottom = 1080 - bb

			#If keep aspect ratio is on
			if keepAspectRatio:
				xSize = aa - xx
				ySize = bb - yy
				if ySize == 0 or xSize / ySize > xMaxSize / yMaxSize:
					wantedTop -= (yMaxSize / xMaxSize * xSize - ySize) / 2
					wantedBottom -= (yMaxSize / xMaxSize * xSize - ySize) / 2
				elif xSize == 0 or xSize / ySize < xMaxSize / yMaxSize:
					wantedLeft -= (xMaxSize / yMaxSize * ySize - xSize) / 2
					wantedRight -= (xMaxSize / yMaxSize * ySize - xSize) / 2

			#Zoom in
			global wantsZoom
			wantsZoom = True

#Toggle follow
def toggleFollow(pressed):
	global followingMouse
	global presses
	if not pressed:
		global wantedLeft
		global wantedTop
		global wantedRight
		global wantedBottom
		mousePos = queryMousePosition()
		followingMouse = not followingMouse
		if followingMouse:
			global currentCamera
			currentCamera = [mousePos.x, mousePos.y]
			xSize = 1920 - currentRight - currentLeft
			ySize = 1080 -  currentBottom - currentTop

			#Save to history
			wantedHistory.append([wantedLeft, wantedTop, wantedRight, wantedBottom])
			wantedUndos.clear()

			#Move crop
			wantedLeft = mousePos.x - xSize / 2
			wantedRight = 1920 - (mousePos.x + xSize / 2)
			wantedTop = mousePos.y - ySize / 2
			wantedBottom = 1080 - (mousePos.y + ySize / 2)

#On script load
def script_load(settings):
	#Load hotkeys
	for hotkeyId in hotkeyDict:
		hk = obs.obs_hotkey_register_frontend(hotkeyId, hotkeyDict[hotkeyId]["description"], hotkeyDict[hotkeyId]["function"])
		hotkeyDict[hotkeyId]["id"] = hk
		save_array = obs.obs_data_get_array(settings, hotkeyId)
		obs.obs_hotkey_load(hk, save_array)
		obs.obs_data_array_release(save_array)	

#On script save
def script_save(settings):
	#Save hotkeys
	for hotkeyId in hotkeyDict:
		save_array = obs.obs_hotkey_save(hotkeyDict[hotkeyId]["id"])
		obs.obs_data_set_array(settings, hotkeyId, save_array)
		obs.obs_data_array_release(save_array)
	
#On script description
def script_description():
	return "Follow mouse and zoom, undo zoom and redo zoom.\n\nBy TIBI4.com"

#On script update
def script_update(settings):
	global xMaxSize
	global yMaxSize
	global followRate
	global zoomRate
	global keepAspectRatio
	global sourceName1
	global sourceName2
	xMaxSize = obs.obs_data_get_int(settings, "xMaxSize")
	yMaxSize = obs.obs_data_get_int(settings, "yMaxSize")
	followRate = obs.obs_data_get_int(settings, "followRate")
	zoomRate = obs.obs_data_get_int(settings, "zoomRate") 
	keepAspectRatio = obs.obs_data_get_bool(settings, "keepAspectRatio")
	print(keepAspectRatio)
	sourceName1 = obs.obs_data_get_string(settings, "sourceName1")
	sourceName2 = obs.obs_data_get_string(settings, "sourceName2")

#On script defaults
def script_defaults(settings):
	obs.obs_data_set_default_int(settings, "xMaxSize", xMaxSize)
	obs.obs_data_set_default_int(settings, "yMaxSize", yMaxSize)
	obs.obs_data_set_default_int(settings, "followRate", followRate)
	obs.obs_data_set_default_int(settings, "zoomRate", zoomRate)
	obs.obs_data_set_default_bool(settings, "keepAspectRatio", keepAspectRatio)

#On script properties
def script_properties():
	props = obs.obs_properties_create()
	obs.obs_properties_add_int(props, "xMaxSize", "Max x size:", 0, 10000, 1)
	obs.obs_properties_add_int(props, "yMaxSize", "Max y size:", 0, 10000, 1)
	obs.obs_properties_add_int(props, "followRate", "Follow speed %:", 0, 100, 1)
	obs.obs_properties_add_int(props, "zoomRate", "Zoom speed %:", 0, 100, 1)
	obs.obs_properties_add_bool(props, "keepAspectRatio", "Keep aspect ratio on select rectangle:")
	sourceList1 = obs.obs_properties_add_list(props, "sourceName1", "Screen source 1:", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	sourceList2 = obs.obs_properties_add_list(props, "sourceName2", "Screen source 2:", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
	sources = obs.obs_enum_sources()
	obs.obs_property_list_add_string(sourceList1, "", "")
	obs.obs_property_list_add_string(sourceList2, "", "")
	if sources is not None:
		for source in sources:
			source_id = obs.obs_source_get_unversioned_id(source)
			if source_id == "monitor_capture":
				name = obs.obs_source_get_name(source)
				obs.obs_property_list_add_string(sourceList1, name, name)
				obs.obs_property_list_add_string(sourceList2, name, name)
		obs.source_list_release(sources)
	return props

ready()