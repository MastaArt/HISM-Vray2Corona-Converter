fn sqr x = x*x

-- vrayCheckProductionRenderer check if V-Ray/V-Ray GPU is the production renderer
-- This is the global instance of the functions used in the macroscripts "checkVRayRenderer", keep them in sync.
-- @returns true if production renderer is V-Ray/V-Ray GPU
fn vrayCheckProductionRenderer = (
	local res = false
	if(renderers.production != undefined) then (
		cid = renderers.production.classid
		res = ((cid[1] == 1941615238) and (cid[2] == 2012806412) or (cid[1] == 1770671000) and (cid[2] == 1323107829))
	)
	res
)

fn getMaxReleaseAsString=(
	local ver=maxversion()
	local result

	if (ver[1]>=10000) then (
		result=(((Integer(ver[1])/Integer(1000))+1998) as String)
	)
	else (
		result="R"+(((ver[1]/1000) as Integer) as String)
	)
	result
)

fn getVRayInstallPath release=(
	local regKeyName="SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
	local regKey
	local subKey
	local result
	local replaceIdx=undefined
	try (
		if (registry.openKey HKEY_LOCAL_MACHINE regKeyName accessRights: #readOnly key: &regKey) do (
			local subKeyNames=#()

			registry.getSubKeyNames regKey names: &subKeyNames

			for i = 1 to subKeyNames.count do (
				if (matchPattern subKeyNames[i] pattern:("V-Ray for 3ds*max "+release+" for*")) do (
					registry.getSubKeyName regKey i name: &subKeyName
					if (registry.openKey regKey subKeyName accessRights: #readOnly key: &subKey) do (
						local vrayCmd
						if (registry.queryValue subKey "UninstallString" value: &vrayCmd) do (
							-- Trim install.log's path and doublequotes too
							vrayCmd=substring vrayCmd ((findString vrayCmd "-uninstall=")+12) -1
							vrayCmd=substring vrayCmd 1 ((findString vrayCmd "\"")-1)

							local fInstallLog=openFile (vrayCmd)
							if (fInstallLog!=undefined) do (
								do (
									vrayCmd=readLine fInstallLog
								) while (((findString vrayCmd "\\img2tiledexr.exe")==undefined) OR (eof fInstallLog))
								-- filter vray command
								result=substring vrayCmd ((findString vrayCmd ":\\")-1) -1
								replaceIdx = findString result "img2tiledexr.exe"
								close fInstallLog
							)
						)
						registry.closeKey subKey
					)
				)
			)
			registry.closeKey regKey
		)
	)
	catch (
		if (subKey!=undefined) do (registry.closeKey subKey)
		if (regKey!=undefined) do (registry.closeKey regKey)
	)

	if replaceIdx!=undefined do (
		maketxResult=replace result replaceIdx ("img2tiledexr.exe" as string).count  "maketx.exe"
		if doesfileExist maketxResult then (
			result=maketxResult
			useMakeTx=true
		) else (
			useMakeTx=false
		)
	)
	result
)

-- used to look up materials that have already been converted
orig_mtls=#()
new_mtls=#()

-- used to look up textures that have already been converted
orig_texmaps=#()
new_texmaps=#()

-- used to look up bitmap textures that have already been converted
orig_bitmaptextures=#()
new_hdritexmaps=#()

listOfConvertedNodesHandles=#()

maxver = (maxVersion())[1]

convertToVRay -- Placeholder for the function, otherwise maxscript returns error when executing
					-- the rollout's convert button event if evaluated with the function defined
					-- afterwards.

useMakeTx = false  --Global variable to instruct the converter to tiled EXR to use makeTX or img2TiledExr to perform the conversion

rollout vraySceneConverterRollout "V-Ray scene converter" width: 460 height: 210 (
	label label_message "All scene materials and raytraced shadows will be converted to V-Ray materials and shadows." width:400 height:26 align:#center offset:[0, 10]

	checkbox check_optReflections "Turn on \"trace reflections\" when converting Standard materials" checked:false width:400 align:#center offset:[0, 10]
	checkbox check_optLights "Convert mr Sun/Sky to V-Ray Sun/Sky" checked:false width:400 align:#center offset:[0, 0]
	checkbox check_optStdMtlOpacityToVRayMtlRefract "Convert Standard material opacity to V-Ray material refraction" checked:false width:400 align:#center
	checkbox check_optConvertOnlySelectedNodes "Convert selected nodes only" checked:false width:400 align:#center
	checkbox check_optConvertPhysicalMtl "Convert Physical Material to VRayMtl" checked:false width:400 align:#center
	dropDownList ddListCameras selection:1 width:319 align:#left offset:[17, 0]

	button btn_convertStart "Convert" width:60 align:#right across:2 offset:[150, 0]
	button btn_convertCancel "Cancel" width:60 align:#right

	on vraySceneConverterRollout open do (
		if (((maxVersion())[1]) >= 18000) then (
			ddListCameras.items = #("Don't convert standard cameras", "Convert standard cameras to V-Ray Physical Camera", "Convert standard cameras to Max Physical Camera")
		)
		else (
			ddListCameras.items = #("Don't convert standard cameras", "Convert standard cameras to V-Ray Physical Camera")
		)
	)

	on btn_convertStart pressed do (
		convertToVRay  check_optConvertOnlySelectedNodes.checked
		destroyDialog vraySceneConverterRollout
	)

	on btn_convertCancel pressed do (
		destroyDialog vraySceneConverterRollout
	)
)

fn convertFrom_Standard origMtl = (
	r=VRayMtl()
	r.name="_VRB."+origMtl.name

	r.texmap_bump=origMtl.bumpMap
	if (r.texmap_bump!=undefined) then (
		r.texmap_bump_on=origMtl.bumpMapEnable
		r.texmap_bump_multiplier=origMtl.bumpMapAmount
	)

	r.texmap_displacement=origMtl.displacementMap
	if (r.texmap_displacement!=undefined) then (
		r.texmap_displacement_on=origMtl.displacementMapEnable
		r.texmap_displacement_multiplier=origMtl.displacementMapAmount
	)

	r.diffuse=origMtl.diffuse
	r.texmap_diffuse=origMtl.diffuseMap
	if (r.texmap_diffuse!=undefined) then (
		r.texmap_diffuse_on=origMtl.diffuseMapEnable
		r.texmap_diffuse_multiplier=origMtl.diffuseMapAmount
	)

	if (origMtl.shaderByName !="Strauss") then (
		r.reflection=origMtl.specular*origMtl.specularLevel*0.01
	)

	if (vraySceneConverterRollout.check_optStdMtlOpacityToVRayMtlRefract.checked) do (
		r.refraction=(Color 255 255 255) * (1.0 - origMtl.opacity*0.01)
	)

	-- unlocked highlights and reflection glossiness no longer supported in V-Ray Next and
	-- that affects reflection and reflection_glossiness initialisation
	local vrMajorVer = 3
	if vrayVersion != undefined do (
		vrMajorVer = (vrayVersion())[1][1] as Integer
	)

	K=2.0^(origMtl.glossiness*0.01*10.0)
	if (origMtl.shaderType==5) then (
		-- phong
		r.brdf_type=0
		if vrMajorVer < 4 do r.reflection=r.reflection*2.0/(K+1.0)
	) else (
		-- blinn
		r.brdf_type=1
		K=K*4
		if vrMajorVer < 4 do r.reflection=r.reflection*8.0/(K+1.0)
	)

	if vrMajorVer > 3 then (
		r.reflection_glossiness=1.0-(1.0/(K+1.0))^(1.0/3.5)
	)
	else (
		r.reflection_lockGlossiness=false
		r.hilight_glossiness=1.0-(1.0/(K+1.0))^(1.0/3.5)
		r.reflection_glossiness=1.0
	)
	r.option_traceReflection=vraySceneConverterRollout.check_optReflections.checked

	r.texmap_opacity=origMtl.opacityMap
	if (r.texmap_opacity!=undefined) then (
		r.texmap_opacity_on=origMtl.opacityMapEnable
		r.texmap_opacity_multiplier=origMtl.opacityMapAmount
	)

	r
)

fn convertFrom_Raytrace origMtl = (
	r=VRayMtl()
	r.name="_VRB."+origMtl.name

	r.texmap_bump=origMtl.bumpMap
	if (r.texmap_bump!=undefined) then (
		r.texmap_bump_on=origMtl.bumpMapEnable
		r.texmap_bump_multiplier=origMtl.bumpMapAmount
	)

	r.texmap_displacement=origMtl.displacementMap
	if (r.texmap_displacement!=undefined) then (
		r.texmap_displacement_on=origMtl.displacementMapEnable
		r.texmap_displacement_multiplier=origMtl.displacementMapAmount
	)

	r.diffuse=origMtl.diffuse
	r.texmap_diffuse=origMtl.diffuseMap
	if (r.texmap_diffuse!=undefined) then (
		r.texmap_diffuse_on=origMtl.diffuseMapEnable
		r.texmap_diffuse_multiplier=origMtl.diffuseMapAmount
	)

	r.reflection=origMtl.spec__color*origMtl.specular_level*0.01*0.5

	K=2.0^(origMtl.glossiness*0.01*10.0)
	if (origMtl.shaderType==1) then (
		-- phong
		r.brdf_type=0
		r.reflection=r.reflection*2.0/(K+1.0)
	) else (
		-- blinn
		r.brdf_type=1
		K=K*4
		r.reflection=r.reflection*8.0/(K+1.0)
	)

	if (origMtl.reflect.r>r.reflection.r) then r.reflection.r=origMtl.reflect.r
	if (origMtl.reflect.g>r.reflection.g) then r.reflection.g=origMtl.reflect.g
	if (origMtl.reflect.b>r.reflection.b) then r.reflection.b=origMtl.reflect.b

	r.reflection_glossiness=1.0-(1.0/(K+1.0))^(1.0/3.5)

	if ((origMtl.reflect.r+origMtl.reflect.g+origMtl.reflect.b)/3.0<1e-6) then r.option_traceReflection=false

	r.texmap_reflection=origMtl.reflectionMap
	if (r.texmap_reflection!=undefined) then (
		r.texmap_reflection_on=origMtl.reflectionMapEnable
		r.texmap_reflection_multiplier=origMtl.reflectionMapAmount
	)

	r.refraction=origMtl.transparecy
	r.refraction_ior=origMtl.Index_of_Refraction

	r.texmap_refraction=origMtl.transparencyMap
	if (r.texmap_refraction!=undefined) then (
		r.texmap_refraction_on=origMtl.transparencyMapEnable
		r.texmap_refraction_multiplier=origMtl.transparencyMapAmount
	)

	r
)

fn convertFrom_fR_Advanced origMtl = (
	r=VRayMtl()
	r.name="_VRB."+origMtl.name

	-- diffuse
	r.diffuse=origMtl.diffuseColor
	r.texmap_diffuse=origMtl.diffuseMap
	r.texmap_diffuse_on=origMtl.useDiffuseMap
	r.texmap_diffuse_multiplier=origMtl.diffuseMapAmount

	-- bump map
	r.texmap_bump=origMtl.bumpMap
	r.texmap_bump_on=origMtl.useBumpMap
	r.texmap_bump_multiplier=origMtl.bumpMapAmount

	-- displacement
	r.texmap_displacement=origMtl.MTDMap
	r.texmap_displacement_on=origMtl.useMTDMap
	r.texmap_displacement_multiplier=origMtl.MTDMapAmount

	-- reflection
	r.reflection=origMtl.reflectFilter
	r.texmap_reflection=origMtl.reflectMap
	r.texmap_reflection_on=origMtl.useReflectMap
	r.texmap_reflection_multiplier=origMtl.reflectMapAmount

	r.reflection_glossiness=1.0-sqr (origMtl.reflectGlossy*0.01)
	r.texmap_reflectionGlossiness=origMtl.reflectBlurryMap
	r.texmap_reflectionGlossiness_on=origMtl.useReflectBlurryMap
	r.texmap_reflectionGlossiness_multiplier=origMtl.reflectBlurryMapAmount

	r.reflection_subdivs=sqrt origMtl.reflectSamples
	r.reflection_fresnel=origMtl.useFresnel
	r.reflection_useInterpolation=origMtl.useReflBlur

	-- refraction
	r.refraction=origMtl.refractFilter
	r.texmap_refraction=origMtl.refractMap
	r.texmap_refraction_on=origMtl.useRefractMap
	r.texmap_refraction_multiplier=origMtl.refractMapAmount

	r.refraction_ior=origMtl.refractIOR
	r.texmap_refractionIOR=origMtl.refractIORMap
	r.texmap_refractionIOR_on=origMtl.useRefractIORMap
	r.texmap_refractionIOR_multiplier=origMtl.refractIORMapAmount

	r.refraction_glossiness=1.0-sqr (origMtl.refractGlossy*0.01)
	r.texmap_refractionGlossiness=origMtl.refractBlurryMap
	r.texmap_refractionGlossiness_on=origMtl.useRefractBlurryMap
	r.texmap_refractionGlossiness_multiplier=origMtl.refractBlurryMapAmount

	r.refraction_subdivs=sqrt origMtl.refractSamples
	r.refraction_useInterpolation=origMtl.useRefrBlur

	r
)

fn convertFrom_fR_Metal origMtl = (
	r=VRayMtl()
	r.name="_VRB."+origMtl.name

	r.diffuse=origMtl.diffuseColor
	r.texmap_diffuse=origMtl.diffuseMap
	r.texmap_diffuse_on=origMtl.diffuseMapEnable
	r.texmap_diffuse_multiplier=origMtl.diffuseMapAmount

	r.reflection=origMtl.reflectColor
	r.texmap_reflection=origMtl.reflectLevelMap
	r.texmap_reflection_on=origMtl.reflectLevelMapEnable
	r.texmap_reflection_multiplier=origMtl.reflectLevelMapAmount

	r
)

fn convertFrom_fR_Glass origMtl = (
	r=VRayMtl()
	r.name="_VRB."+origMtl.name

	r.diffuse=origMtl.diffuseColor
	r.texmap_diffuse=origMtl.diffuseMap
	r.texmap_diffuse_on=origMtl.diffuseMapEnable
	r.texmap_diffuse_multiplier=origMtl.diffuseMapAmount

	r.reflection=origMtl.reflectColor
	r.reflection_fresnel=origMtl.useFresnel
	r.texmap_reflection=origMtl.reflectMap
	r.texmap_reflection_on=origMtl.reflectMapEnable
	r.texmap_reflection_multiplier=origMtl.reflectMapAmount

	r.refraction=origMtl.refractColor
	r.refraction_ior=origMtl.refractIOR
	r.texmap_refraction=origMtl.refractMap
	r.texmap_refraction_on=origMtl.refractMapEnable
	r.texmap_refraction_multiplier=origMtl.refractMapAmount

	r.refraction_affectShadows=true
	r.refraction_affectAlpha=1

	r
)

fn createVRayMtl=undefined
fn createVRayTexture=undefined

fn convertFromBlend orig_mtl = (
	r=VRayBlendMtl()
	r.name="_VRB."+orig_mtl.name

	r.baseMtl = createVRayMtl orig_mtl.map1
	r.coatMtl[1] = createVRayMtl orig_mtl.map2
	r.blend[1]=(orig_mtl.mixAmount*0.01)*(color 255 255 255)
	if orig_mtl.mask != undefined then (
		r.texmap_blend[1] = createVRayTexture orig_mtl.mask
		if orig_mtl.maskEnabled == off then r.texmap_blend_multiplier[1]=0
	)

	r
)

fn convertFromShellac orig_mtl = (
	r=VRayBlendMtl()
	r.name="_VRB."+orig_mtl.name
	r.additiveMode=true

	r.baseMtl = createVRayMtl orig_mtl.shellacMtl1
	r.coatMtl[1] = createVRayMtl orig_mtl.shellacMtl2
	r.blend[1]=(orig_mtl.shellacColorBlend*0.01)*(color 255 255 255)

	r
)

fn convertFromDoubleSided orig_mtl = (
	r=VRay2SidedMtl()
	r.name="_VRB."+orig_mtl.name

	r.frontMtl = createVRayMtl orig_mtl.material1
	r.backMtl = createVRayMtl orig_mtl.material2
	r.translucency=orig_mtl.translucency*0.01*(color 255 255 255)
	r.backMtlOn=orig_mtl.map2Enabled

	r
)

fn vrayRGBtoY inputmap type =
(
	-- RGB intensity as ITU BT.709 Y = 0.2126 R + 0.7152 G + 0.0722 B
	-- If not then use ITU BT.601 Y = 0.299 R + 0.587 G + 0.114 B
	rgbColors=#(#(([0.2126,0.2126,0.2126]*255) as color,([0.7152,0.7152,0.7152]*255) as color,([0.0722,0.0722,0.0722]*255) as color),
				#(([0.299,0.299,0.299]*255) as color,([0.587,0.587,0.587]*255) as color,([0.114,0.114,0.114]*255) as color))
	theRGBTint = RGBTint name:"RGB to Intensity" map1:inputmap
	if type == "BT.709" then
	(
		theRGBTint.Red = rgbColors[1][1]
		theRGBTint.Green = rgbColors[1][2]
		theRGBTint.Blue = rgbColors[1][3]
	)
	else if type == "BT.601" do
	(
		theRGBTint.Red = rgbColors[2][1]
		theRGBTint.Green = rgbColors[2][2]
		theRGBTint.Blue = rgbColors[2][3]
	)
	theRGBTint
)

fn vrayMultiplyRGBWeight rgbMap weightMap type= -- type is either "BT.709" or "BT.601"
(
	theCompTex = VRayCompTex name:"Weight Multiplier"
	theCompTex.sourceA = vrayRGBtoY weightMap type
	theCompTex.sourceB = rgbMap
	theCompTex.operator = 3 -- Multiply
	theCompTex
)

-- This function uses the Max Output map (Or a VRayCompTex, and a color, to do 1-texture) to invert the incoming texture
-- Only if it's not a bitmap (i.e. doesn't have its own .output section), or if it is instanced.
fn vrayInvertTexture rgbMap doVRayOnly=
(
	rgbMapClass=classof rgbMap
	if rgbMapClass != Bitmaptexture and rgbMapClass != VRayBitmap or (refhierarchy.IsRefTargetInstanced rgbMap) then
	(
		if doVRayOnly then
		(
			theCompTex=VRayCompTex name:"Inverter"
			theCompTex.sourceA = vrayColor color:white name:"One"
			theCompTex.sourceB = rgbMap
			theCompTex.operator = 1 --subtract (A-B)
			theOutput = theCompTex
		)
		else
		(
			theOutput=Output name:("Invert " + rgbMap.name) map1:rgbMap
			theOutput.output.invert = true
		)
	)
	else -- If it's a non-instanced bitmap, it's safe to toggle its invert flag.
	(
		rgbMap.output.invert = not rgbMap.output.invert --toggle, do not set!
		theOutput = rgbMap
	)
	theOutput
)

fn convertFrom_PhysicalMaterial im =
(
	msgString = ("Working on " + im.name + "\n")
	om = VRayMtl()
	om.name = "_VRB."+im.name

	-- Diffuse

	if im.base_weight_map != undefined then
	(
		om.diffuse=im.base_color --No need to mult by the float weight as it's overridden by the map
		if im.base_color_map != undefined then
		(
			om.texmap_diffuse = vrayMultiplyRGBWeight im.base_color_map im.base_weight_map "BT.709" -- Alternatively, "BT.601"
		)
		else
		(
			om.texmap_diffuse = vrayMultiplyRGBWeight (VrayColor name:"diffuse_color" color:im.base_color) im.base_weight_map "BT.709" -- Alternatively, "BT.601"
		)
	)
	else
	(
		om.diffuse=im.base_weight*im.base_color --Mult by the weight float as no map overrides it
		om.texmap_diffuse = im.base_color_map
	)
	om.texmap_diffuse_on = im.base_color_map_on

	om.diffuse_roughness = im.diff_roughness
	om.texmap_roughness = im.diff_rough_map
	om.texmap_roughness_on = im.diff_rough_map_on

	-- Reflection
	if im.reflectivity_map != undefined then
	(
		om.reflection=im.refl_color
		if im.refl_color_map != undefined then
		(
			om.texmap_reflection = vrayMultiplyRGBWeight im.refl_color_map im.reflectivity_map "BT.709"
		)
		else
		(
			om.texmap_reflection = vrayMultiplyRGBWeight (VrayColor name:"reflection_color" color:im.refl_color) im.reflectivity_map "BT.709"
		)
	)
	else
	(
		om.reflection = im.reflectivity*im.refl_color
		om.texmap_reflection = im.refl_color_map
	)

	om.texmap_reflection_on=im.refl_color_map_on

	om.brdf_useRoughness = not im.roughness_inv -- Matches BRDF use of gloss/rough
	om.reflection_glossiness = im.roughness
	om.texmap_reflectionGlossiness = im.roughness_map
	om.texmap_reflectionGlossiness_on = im.roughness_map_on

	om.reflection_metalness = im.metalness
	om.texmap_metalness = im.metalness_map
	om.texmap_metalness_on = im.metalness_map_on

	om.reflection_fresnel = true -- Forced through. there is no way to mimic the custom curve mode anyway.
	om.reflection_IOR = im.trans_ior -- IOR needs forcing too, the Physmat has only one.
	om.texmap_reflectionIOR = im.trans_ior_map
	om.texmap_reflectionIOR_on = im.trans_ior_map_on
	om.option_glossyFresnel = off -- Otherwise it won't match

	-- Refraction
	if (im.transparency != 0 or im.transparency_map != undefined ) and --verify transparency is actually active.
	(im.trans_color!=black or im.trans_color_map!=undefined ) do
	(
		if im.transparency_map != undefined then --weight is textured
		(
			om.refraction=im.trans_color --No need to mult by the float weight as it's overridden by the map
			if im.trans_color_map != undefined then
			(
				om.texmap_refraction = vrayMultiplyRGBWeight im.trans_color_map im.transparency_map "BT.709"
			)
			else
			(
				om.texmap_refraction = vrayMultiplyRGBWeight (VrayColor name:"refraction_color" color:im.trans_color) im.transparency_map "BT.709"
			)
		)
		else
		(
			om.refraction=im.transparency*im.trans_color
			om.texmap_refraction=im.trans_color_map
		)
		om.texmap_refraction_on = im.trans_color_map_on

		-- Roughness can either use the REFLECTION controls (maps, colors and weights) or the REFRACTION controls.
		-- If it uses the reflection controls, we just need to duplicate the maps, the BRDF mode is all set.
		-- If it uses its own controls, we need to verify its BRDF is set to either gloss or rough, and invert maps as needed (VRayMtl has one option for this, physmat has two.)
		if im.trans_roughness_lock then --use REFLECTION controls
		(
			om.refraction_glossiness = im.roughness
			om.texmap_refractionGlossiness = im.roughness_map
			om.texmap_refractionGlossiness_on = im.roughness_map_on
		)
		else -- Use REFRACTION controls
		(
			if im.trans_roughness_inv == im.roughness_inv then -- Matches reflection, copy over
			(
				om.refraction_glossiness = im.trans_roughness
				om.texmap_refractionGlossiness = im.trans_rough_map
			)
			else -- Refraction uses roughness, use reciprocal
			(
				om.refraction_glossiness = 1-im.trans_roughness
				if im.trans_rough_map != undefined do om.texmap_refractionGlossiness = vrayInvertTexture im.trans_rough_map false
			)
			om.texmap_refractionGlossiness_on = im.trans_rough_map_on
		)
	)

	-- Luminance/(1500.0/pi) = scene units multiplier
	if (im.emission != 0 or im.emission_map != undefined)  do
	(
		if (im.emit_color != black or im.emit_color_map != undefined ) do
		(
			if im.emission_map != undefined then --weight is textured
			(
				om.selfIllumination=im.emit_color
				if im.emit_color_map != undefined then
				(
					om.texmap_self_illumination = vrayMultiplyRGBWeight im.emit_color_map im.emission_map "BT.709"
				)
				else -- We use a vraycolormap with the emission color instead.
				(
					om.texmap_self_illumination = vrayMultiplyRGBWeight (vrayColor name:"selfillum_color" color:im.emit_color) im.emission_map "BT.709"
				)
			)
			else
			(
				om.selfIllumination=im.emission*im.emit_color
				om.texmap_self_illumination=im.emit_color_map
			)
			om.selfIllumination_multiplier = im.emit_luminance / (1500.0/pi)
			om.texmap_self_illumination_on = im.emit_color_map_on
		)
	)

	-- Anisotropy is a skip, broken in the physmat
	-- Still warn the user
	(
		if im.anisotropy != 1.0 or anisotropy_map != undefined do
		(
			msgString += "\t\"Anisotropy\" isn't supported: Skipping\n"
		)
	)

	-- Special maps section:
	-- Bump
	om.texmap_bump = im.bump_map
	om.texmap_bump_multiplier = 100*im.bump_map_amt
	om.texmap_bump_on = im.bump_map_on

	-- Displacement
	om.texmap_displacement = im.displacement_map
	om.texmap_displacement_multiplier = 100*im.displacement_map_amt
	om.texmap_displacement_on = im.displacement_map_on

	-- Opacity

	om.texmap_opacity_on = im.cutout_map_on
	om.texmap_opacity = im.cutout_map
	-- Change to clip mode
	if im.cutout_map != undefined do om.option_opacityMode = 1

	-- Coat
	om.coat_amount = im.coating
	om.texmap_coat_amount = im.coat_map
	om.texmap_coat_amount_on = im.coat_map_on
	om.coat_color = im.coat_color
	om.texmap_coat_color = im.coat_color_map
	om.texmap_coat_color_on = im.coat_color_map_on
	om.coat_glossiness = if im.coat_roughness_inv then im.coat_roughness else 1-im.coat_roughness
	if im.coat_roughness_inv then
	(
		om.texmap_coat_glossiness = im.coat_rough_map --if undefined it's no issue
	)
	else
	(
		if im.coat_rough_map!= undefined do vrayInvertTexture im.coat_rough_map  false -- If undefined it generates an erring texture
	)
	om.texmap_coat_glossiness_on = im.coat_rough_map_on
	om.coat_ior = im.coat_ior

	om.texmap_coat_bump_multiplier = 100*im.clearcoat_bump_map_amt
	om.texmap_coat_bump_on = im.coat_bump_map_on
	om.texmap_coat_bump = im.coat_bump_map

	-- If there is translucency, wrap the material into a VRay2SidedMtl
	om.option_reflectOnBack = true
	if im.thin_walled then -- TRANSLUCENCY
	(
		if im.scattering != 0.0 or im.scattering_map != undefined then -- We have translucency, thin-walled was valid and translatable
		(
			om.option_reflectOnBack = false

			m = VRay2SidedMtl frontMtl:om name:"vray_translucency_wrapper"
			m.mult_by_front_diffuse = true

			if im.scattering_map != undefined then -- Weight is textured
			(
				m.translucency=im.sss_color -- No need to mult by the float weight as it's overridden by the map
				if im.sss_color_map != undefined then
				(
					m.texmap_translucency = vrayMultiplyRGBWeight im.sss_color_map im.scattering_map "BT.709"
				)
				else
				(
					m.texmap_translucency = vrayMultiplyRGBWeight (vrayColor name:"translucency_color" color:im.sss_color) im.scattering_map "BT.709"
				)
			)
			else
			(
				m.translucency=im.scattering*im.sss_color
				m.texmap_translucency=im.sss_color_map
			)
			om = m --Replace the original material with the wrapped.
		)
		else
		(
			MsgString += "\t\"Thin-Walled\" isn't supported, and no translucency was found: Skipping\n"
		)
	)
	else -- SSS
	(
		-- Skip it for now. Blend with fastSSS2?
		MsgString += "\t\"SSS\" isn't supported: Skipping\n"
	)
	print MsgString
	om
)

fn convertFrom_Architectural orig_mtl = (
	r=VRayMtl()
	r.name="_VRB."+orig_mtl.name

	-- diffuse component
	r.diffuse=orig_mtl.diffuse
	r.texmap_diffuse=orig_mtl.diffuseMap
	if (r.texmap_diffuse!=undefined) then (
		r.texmap_diffuse_on=orig_mtl.diffuseMapEnable
		r.texmap_diffuse_multiplier=orig_mtl.diffuseMapAmount
	)

	-- specular component
	r.reflection=(color 255 255 255)
	r.texmap_reflection=orig_mtl.shininessMap
	r.reflection_fresnel=true
	r.reflection_glossiness=(orig_mtl.shininess*0.01)*0.25+0.75

	-- refraction
	r.refraction=orig_mtl.transparency*0.01*(color 255 255 255)
	r.refraction_ior=orig_mtl.ior

	-- if there is luminance, wrap the material into a VRayBlendMtl and add a VRayLightMtl on top of it
	if orig_mtl.luminance>0 then (
		local l=VRayLightMtl()
		l.color=orig_mtl.diffuse
		l.multiplier=orig_mtl.luminance
		l.opacity_texmap=VRayColor()
		l.opacity_texmap.color=(color 0 0 0)

		local m=VRayBlendMtl()
		m.baseMtl=r
		m.coatMtl[1]=l
		m.blend[1]=(color 255 255 255)

		r=m
	)

	-- if there is translucency, wrap the material into a VRay2SidedMtl
	if orig_mtl.translucency>0 then (
		local m=VRay2SidedMtl()
		m.frontMtl=r
		m.translucency=orig_mtl.translucency*0.01*(color 255 255 255)
		r=m
	)

	r
)

fn convertFrom_CoronaMtl orig_mtl = (
	r=VRayMtl()
	r.name="_VRB."+orig_mtl.name

	--Diffuse
	r.diffuse = orig_mtl.levelDiffuse * orig_mtl.colorDiffuse
	r.texmap_diffuse=orig_mtl.texmapDiffuse
	if r.texmap_diffuse != undefined then(
		r.texmap_diffuse_on = orig_mtl.texmapOnDiffuse
		r.texmap_diffuse_multiplier = orig_mtl.mapAmountDiffuse
	)

	--Reflection
	r.reflection = orig_mtl.levelReflect  * orig_mtl.colorReflect
	r.texmap_reflection = orig_mtl.texmapReflect
	if r.texmap_reflection != undefined then(
		r.texmap_reflection_on = orig_mtl.texmapOnReflect
		r.texmap_reflection_multiplier = orig_mtl.mapamountReflect
	)

	r.reflection_fresnel = true
	if orig_mtl.fresnelIor == orig_mtl.Ior then
	(
		r.reflection_lockIOR = true
		r.reflection_ior = orig_mtl.ior
		r.refraction_ior = orig_mtl.ior
	)else(
		r.reflection_lockIOR = false
		r.reflection_ior = orig_mtl.fresnelIor
	)

	r.texmap_reflectionIOR = orig_mtl.texmapFresnelIor
	if r.texmap_reflectionIOR != undefined then(
		r.texmap_reflectionIOR_on = orig_mtl.texmapOnFresnelIor
		r.texmap_reflectionIOR_multiplier = orig_mtl.mapamountFresnelIor
	)

	r.reflection_glossiness = orig_mtl.reflectGlossiness
	r.texmap_reflectionGlossiness = orig_mtl.texmapReflectGlossiness
	if r.texmap_reflectionGlossiness != undefined then(
		r.texmap_reflectionGlossiness_on = orig_mtl.texmapOnReflectGlossiness
		r.texmap_reflectionGlossiness_multiplier = orig_mtl.mapamountReflectGlossiness
	)

	--Anisotropy
	r.anisotropy = orig_mtl.anisotropy
	r.texmap_anisotropy = orig_mtl.texmapReflectAnisotropy
	if r.texmap_anisotropy != undefined then(
		r.texmap_anisotropy_on = orig_mtl.texmapOnAnisotropy
		r.texmap_anisotropy_multiplier = orig_mtl.mapamountAnisotropy
	)
	r.anisotropy_rotation = orig_mtl.anisotropyRotation
	r.texmap_anisotropy_rotation = orig_mtl.texmapReflectAnisotropyRotation
	if r.texmap_anisotropy_rotation != undefined then(
		r.texmap_anisotropy_rotation_on = orig_mtl.texmapOnAnisotropyRotation
		r.texmap_anisotropy_rotation_multiplier = orig_mtl.mapamountAnisotropyRotation
	)

	--Refraction
	r.refraction = orig_mtl.levelRefract*orig_mtl.colorRefract
	r.texmap_refraction = orig_mtl.texmapRefract
	if r.texmap_refraction != undefined then(
		r.texmap_refraction_on = orig_mtl.texmapOnRefract
		r.texmap_refraction_multiplier = orig_mtl.mapamountRefract
	)

	r.refraction_ior = orig_mtl.ior
	r.texmap_refractionIOR = orig_mtl.texmapIor
	if r.texmap_refractionIOR != undefined then(
		r.texmap_refractionIOR_on = orig_mtl.texmapOnIor
		r.texmap_refractionIOR_multiplier = orig_mtl.mapamountIor
	)

	r.refraction_glossiness = orig_mtl.refractGlossiness
	r.texmap_refractionGlossiness = orig_mtl.texmapRefractGlossiness
	if r.texmap_refractionGlossiness != undefined then(
		r.texmap_refractionGlossiness_on = orig_mtl.texmapOnRefractGlossiness
		r.texmap_refractionGlossiness_multiplier = orig_mtl.mapamountRefractGlossiness
	)

	r.refraction_affectShadows = not orig_mtl.caustics
	if  orig_mtl.thin do r.refraction_ior = 1.0

	--Opacity
	r.texmap_opacity = orig_mtl.texmapOpacity
	if r.texmap_opacity != undefined then(
		r.texmap_opacity_on = orig_mtl.texmapOnOpacity
		r.texmap_opacity_multiplier = orig_mtl.mapamountOpacity
	)

	--Bumpmap
	r.texmap_bump = orig_mtl.texmapBump
	if r.texmap_bump != undefined then(
		r.texmap_bump_on = orig_mtl.texmapOnBump
		r.texmap_bump_multiplier = 100.0*orig_mtl.mapamountBump
	)

	--Absorption
	r.refraction_fogMult  = if orig_mtl.absorptionDistance == 0.0 then 0.0 else 1.0/orig_mtl.absorptionDistance
	r.refraction_fogColor  = orig_mtl.absorptionColor

	--Displacement
	r.texmap_displacement = orig_mtl.texmapDisplace
	if r.texmap_displacement != undefined then(
		r.texmap_displacement_on = orig_mtl.texmapOnDisplacement
		r.texmap_displacement_multiplier = (orig_mtl.displacementMaximum - orig_mtl.displacementMinimum) --(Displace_amount) : worldUnits
	)

	--Self illumination
	r.selfIllumination_multiplier = orig_mtl.levelSelfIllum
	r.selfIllumination = if orig_mtl.levelSelfIllum == 0.0 then black else orig_mtl.colorSelfIllum
	r.texmap_self_illumination = orig_mtl.texmapSelfIllum
	if r.texmap_self_illumination != undefined then(
		r.texmap_self_illumination_on = orig_mtl.texmapOnSelfIllum
		r.texmap_self_illumination_multiplier = orig_mtl.mapamountSelfIllum
	)

	-- Translucency
	if orig_mtl.levelTranslucency > 0.0 then(
		
		newVRay2SidedMtl = VRay2SidedMtl name:("vray "+orig_mtl.name)
		newVRay2SidedMtl.frontMtl = r
	
			/*if orig_mtl.texmapTranslucency == undefined then(
				newVRay2SidedMtl.texmap_translucency_multiplier = 100.0*orig_mtl.levelTranslucency
				newVRay2SidedMtl.Translucency = orig_mtl.colorTranslucency
			)
			if orig_mtl.texmapTranslucency != undefined and orig_mtl.texmapOnTranslucency == true then(
				theMix = Mix map1: orig_mtl.texmapTranslucency color2: orig_mtl.colorTranslucency mixAmount: orig_mtl.mapamountTranslucency
				newVRay2SidedMtl.texmap_translucency_multiplier = 100.0*orig_mtl.levelTranslucency
				newVRay2SidedMtl.Translucency = white
				newVRay2SidedMtl.texmap_translucency = theMix
			)*/
		
		
		/*newVRay2SidedMtl.force1SidedSubMtls = false
		newVRay2SidedMtl.backMtlOn = true
		local cp = copy (newVRay2SidedMtl.frontMtl)
		newVRay2SidedMtl.backMtl = cp*/
		
		---!!! MastaMan edition
		
		local vc = VRayColor()
		vc.color = color 128 128 128
		
		local cc = ColorCorrection()	
		cc.name = "_VRB."+orig_mtl.name
		cc.map = vc
		
		newVRay2SidedMtl.texmap_translucency = cc		
		newVRay2SidedMtl.texmap_translucency_multiplier = 26
		
		return newVRay2SidedMtl
	) else return r
)

fn convertFrom_CoronaLayeredMtl orig_mtl = (
	r=VRayBlendMtl()
	r.name="_VRB."+orig_mtl.name

	r.baseMtl = orig_mtl.baseMtl
	for iLayer = 1 to orig_mtl.layers.count - 1 do (
		r.coatMtl[iLayer] = orig_mtl.layers[iLayer]
		r.texmap_blend[iLayer] = orig_mtl.mixmaps[iLayer]
		resVal = orig_mtl.amounts[iLayer] * 255.0 /100.0
		r.blend[iLayer] = (color resVal resVal resVal)
		if hasProperty orig_mtl #maskAmounts then (
			r.texmap_blend_multiplier[iLayer] = orig_mtl.maskAmounts[iLayer]
		)
		if hasProperty r #coatMtl_enable then(  -- Vray 3.3
			if orig_mtl.layersOn[iLayer] = false then r.coatMtl_enable[iLayer] == false
		)
	)

	return r
)

fn convertFrom_CoronaLightMtl orig_mtl = (
	r=VRayLightMtl()
	r.name="_VRB."+orig_mtl.name

	r.color = orig_mtl.color
	r.multiplier = orig_mtl.intensity
	r.directLight_on = orig_mtl.emitLight

	if orig_mtl.texmap != undefined then(
		r.texmap_on = orig_mtl.texmapOn
		r.texmap = orig_mtl.texmap
	)
	if orig_mtl.opacityTexmap != undefined then(
		r.opacity_texmap_on = orig_mtl.opacityTexmapOn
		r.opacity_texmap = orig_mtl.opacityTexmap
	)
	return r
)

fn convertFrom_CoronaRaySwitchMtl orig_mtl = (
	r = VRayOverrideMtl()
	r.name="_VRB."+orig_mtl.name

	r.baseMtl = orig_mtl.directMtl
	r.giMtl = orig_mtl.giMtl
	r.reflectMtl = orig_mtl.reflectMtl
	r.refractMtl = orig_mtl.refractMtl

	return r
)

fn convertFrom_CoronaVolumeMtl orig_mtl = (
	vr=VRayScatterVolume()
	vr.name="_VRB."+orig_mtl.name

	vr.overall_color = orig_mtl.absorptionColor
	vr.sss_color = orig_mtl.scatteringColor
	vr.scatter_color = orig_mtl.absorptionColor
	vr.phase_function = orig_mtl.scatteringDirectionality
	vr.scatter_radius = orig_mtl.absorptionDist
	if orig_mtl.singleBounce then vr.bounces = 1

	if orig_mtl.absorptionColorTexmap != undefined and orig_mtl.absorptionColorTexmapOn == true then (
		vr.texmap_overall_color = orig_mtl.absorptionColorTexmap
		vr.texmap_scatter_color = orig_mtl.absorptionColorTexmap
	)

	if orig_mtl.scatteringColorTexmap != undefined and orig_mtl.scatteringColorTexmapOn == true then (
		vr.texmap_sss_color = orig_mtl.scatteringColorTexmap
	)

	if orig_mtl.emissionDist > 0 then (
		vrLightMtl=VRayLightMtl()
		vrLightMtl.name = "vraylight "+orig_mtl.name
		vrLightMtl.color = orig_mtl.emissionColor
		vrLightMtl.multiplier = (1.0f / orig_mtl.emissionDist)

		vrColorMap = VRayColor()
		vrColorMap.color = (Color 0 0 0)
		vrLightMtl.opacity_texmap = vrColorMap

		vrBlendMtl = VRayBlendMtl()
		vrBlendMtl.name = "vrayblend "+orig_mtl.name
		vrBlendMtl.baseMtl = vr
		vrBlendMtl.coatMtl[1] = vrLightMtl
		return vrBlendMtl
	)

	return vr
)

fn convertFrom_CoronaShadowCatcherMtl orig_mtl = (
	vrwrap=VRayMtlWrapper()
	vrwrap.name="_VRB."+orig_mtl.name

	vrwrap.matteSurface = true
	vrwrap.alphaContribution = case orig_mtl.alphaMode of (
		1: 1.0f
		2: -1.0f
		3: 0.0f
		default: -1.0f
	)
	vrwrap.matte_shadows = true
	vrwrap.matte_shadowsAffectAlpha = true
	vrwrap.matte_shadowBrightness = orig_mtl.shadowAmount

	vr=VRayMtl()
	vr.diffuse = orig_mtl.backplateColor
	if orig_mtl.backplateTexmap != undefined then (
		vr.texmap_diffuse = orig_mtl.backplateTexmap
		vr.texmap_diffuse_on = true
	)

	--Reflection
	vr.reflection = orig_mtl.reflectLevel  * orig_mtl.colorReflect
	vr.texmap_reflection = orig_mtl.reflectColorTexmap

	vr.reflection_fresnel = true
	vr.reflection_lockIOR = false
	vr.reflection_ior = orig_mtl.reflectIor
	vr.reflection_glossiness = orig_mtl.reflectGlossiness

	vr.texmap_bump = orig_mtl.bump
	if vr.texmap_bump != undefined then(
		vr.texmap_bump_on = true
		vr.texmap_bump_multiplier = 100.0*orig_mtl.bumpAmount
	)

	vrwrap.baseMtl = vr
	return vrwrap
)

fn convertFrom_CoronaHairMtl orig_mtl = (
	vr=VRayHairNextMtl()
	vr.name="_VRB."+orig_mtl.name

	vr.melanin = orig_mtl.melanin
	vr.random_melanin = orig_mtl.randomizeMelanin
	vr.texmap_melanin_on = orig_mtl.texmapOnMelanin
	vr.texmap_melanin_multiplier = orig_mtl.mapamountMelanin
	vr.texmap_melanin = orig_mtl.texmapMelanin
	vr.pheomelanin = orig_mtl.pheomelanin

	vr.dye_color = orig_mtl.levelTint * orig_mtl.colorTint
	vr.texmap_dye_color_on = orig_mtl.texmapOnTint
	vr.texmap_dye_color_multiplier = orig_mtl.mapamountTint
	if (orig_mtl.levelTint == 1) then (
		vr.texmap_dye_color = orig_mtl.texmapTint
	) else if (orig_mtl.levelTint == 0) then (
		vr.texmap_dye_color_on = off
		vr.texmap_dye_color = orig_mtl.texmapTint
	) else (
		outTexDye = output()
		outTexDye.map1 = orig_mtl.texmapTint
		outTexDye.output.output_amount = orig_mtl.levelTint
		vr.texmap_dye_color = outTexDye
	)

	vr.opacity = orig_mtl.levelOpacity * orig_mtl.colorOpacity
	vr.texmap_opacity_on = orig_mtl.texmapOnOpacity
	vr.texmap_opacity_multiplier = orig_mtl.mapamountOpacity
	if (orig_mtl.levelOpacity == 1) then (
		vr.texmap_opacity = orig_mtl.texmapOpacity
	) else if (orig_mtl.levelOpacity == 0) then (
		vr.texmap_opacity_on = off
		vr.texmap_opacity = orig_mtl.texmapOpacity
	) else (
		outTexOpacity = output()
		outTexOpacity.map1 = orig_mtl.texmapOpacity
		outTexOpacity.output.output_amount = orig_mtl.levelOpacity
		vr.texmap_opacity = outTexOpacity
	)

	vr.glossiness = orig_mtl.glossiness
	vr.texmap_glossiness_on = orig_mtl.texmapOnGlossiness
	vr.texmap_glossiness_multiplier = orig_mtl.mapamountGlossiness
	vr.texmap_glossiness = orig_mtl.texmapGlossiness
	vr.primary_glossiness_boost = orig_mtl.colorlessGlossiness
	vr.texmap_primary_glossiness_boost_on = orig_mtl.texmapOnColorlessGlossiness
	vr.texmap_primary_glossiness_boost_multiplier = orig_mtl.mapamountColorlessGlossiness
	vr.texmap_primary_glossiness_boost = orig_mtl.texmapColorlessGlossiness
	vr.highlight_shift = orig_mtl.highlightShift

	vr.secondary_tint = orig_mtl.coloredSpecular
	vr.texmap_secondary_tint = orig_mtl.texmapColoredSpecular
	vr.texmap_secondary_tint_on = orig_mtl.texmapOnColoredSpecular
	vr.texmap_secondary_tint_multiplier = orig_mtl.mapamountColoredSpecular

	vr.primary_tint = orig_mtl.colorlessSpecular
	vr.texmap_primary_tint = orig_mtl.texmapColorlessSpecular
	vr.texmap_primary_tint_on = orig_mtl.texmapOnColorlessSpecular
	vr.texmap_primary_tint_multiplier = orig_mtl.mapamountColorlessSpecular

	vr.transmission_tint = orig_mtl.transmission
	vr.texmap_transmission_tint = orig_mtl.texmapTransmission
	vr.texmap_transmission_tint_on = orig_mtl.texmapOnTransmission
	vr.texmap_transmission_tint_multiplier = orig_mtl.mapamountTransmission

	vr.diffuse_amount = orig_mtl.levelDiffuse
	vr.diffuse_color = orig_mtl.colorDiffuse
	vr.texmap_diffuse_color = orig_mtl.texmapDiffuse
	vr.texmap_diffuse_color_on = orig_mtl.texmapOnDiffuse
	vr.texmap_diffuse_color_multiplier = orig_mtl.mapAmountDiffuse

	vr.softness = orig_mtl.softness
	vr.texmap_softness = orig_mtl.texmapSoftness
	vr.texmap_softness_on = orig_mtl.texmapOnSoftness
	vr.texmap_softness_multiplier = orig_mtl.mapamountSoftness

	vr.ior = orig_mtl.ior
	vr.texmap_ior = orig_mtl.texmapIor
	vr.texmap_ior_on = orig_mtl.texmapOnIor
	vr.texmap_ior_multiplier = orig_mtl.mapamountIor

	vr
)

fn convertFrom_CoronaSkinMtl orig_mtl = (
	vr=VRayALSurfaceMtl()
	vr.name="_VRB."+orig_mtl.name

	vr.sss_density_scale = orig_mtl.sssRadiusScale

	vr.opacity = orig_mtl.opacityLevel*orig_mtl.opacityColor
	if (orig_mtl.texmapOpacityColor != undefined) do (
		vr.opacity_texture_on = orig_mtl.texmapOnOpacityColor
		vr.opacity_texture_multiplier = orig_mtl.mapamountOpacityColor
		if (orig_mtl.opacityLevel == 1) then (
			vr.opacity_texture = orig_mtl.texmapOpacityColor
		) else if (orig_mtl.opacityLevel == 0) then (
			vr.opacity_texture_on = off
			vr.opacity_texture = orig_mtl.texmapOpacityColor
		) else (
			outTexOpacity = output()
			outTexOpacity.map1 = orig_mtl.texmapOpacityColor
			outTexOpacity.output.output_amount = orig_mtl.opacityLevel
			vr.opacity_texture = outTexOpacity
		)
	)

	vr.displacement_texture = orig_mtl.texmapDisplace
	vr.displacement_texture_on = orig_mtl.texmapOnDisplace
	--vr.displacement_texture_multiplier = displaceMinimum?, displaceWaterLevel?, displaceMaximum?

	vr.bump_texture = orig_mtl.texmapBump
	vr.bump_texture_on = orig_mtl.texmapOnBump
	vr.bump_texture_multiplier = orig_mtl.mapamountBump

	vr.diffuse_color = orig_mtl.skinColor
	vr.diffuse_strength = orig_mtl.skinLevel
	vr.diffuse_color_texture = orig_mtl.texmapSkinColor
	vr.diffuse_color_texture_on = orig_mtl.texmapOnSkinColor
	vr.diffuse_color_texture_multiplier = orig_mtl.mapamountSkinColor
	vr.sss_mix = orig_mtl.sssAmount
	vr.sss_mix_texture = orig_mtl.texmapSssAmount
	vr.sss_mix_texture_on = orig_mtl.texmapOnSssAmount
	vr.sss_mix_texture_multiplier = orig_mtl.mapamountSssAmount
	vr.sss_mode = orig_mtl.sssMode
	if orig_mtl.sssMode == 0 then vr.sss_mode = 1
	else vr.sss_mode = 0

	--SSS1
	vr.sss1_color = orig_mtl.sss1Color
	vr.sss1_color_texture = orig_mtl.texmapSss1Color
	vr.sss1_color_texture_on = orig_mtl.texmapOnSss1Color
	vr.sss1_color_texture_multiplier = orig_mtl.mapamountSss1Color
	vr.sss1_weight = orig_mtl.sss1Weight
	vr.sss1_weight_texture = orig_mtl.texmapSss1Weight
	vr.sss1_weight_texture_on = orig_mtl.texmapOnSss1Weight
	vr.sss1_weight_texture_multiplier = orig_mtl.mapamountSss1Weight
	vr.sss1_radius = orig_mtl.sss1Radius
	vr.sss1_radius_texture = orig_mtl.texmapSss1Radius
	vr.sss1_radius_texture_on = orig_mtl.texmapOnSss1Radius
	vr.sss1_radius_texture_multiplier = orig_mtl.mapamountSss1Radius

	--SSS2
	vr.sss2_color = orig_mtl.sss2Color
	vr.sss2_color_texture = orig_mtl.texmapSss2Color
	vr.sss2_color_texture_on = orig_mtl.texmapOnSss2Color
	vr.sss2_color_texture_multiplier = orig_mtl.mapamountSss2Color
	vr.sss2_weight = orig_mtl.sss2Weight
	vr.sss2_weight_texture = orig_mtl.texmapSss2Weight
	vr.sss2_weight_texture_on = orig_mtl.texmapOnSss2Weight
	vr.sss2_weight_texture_multiplier = orig_mtl.mapamountSss2Weight
	vr.sss2_radius = orig_mtl.sss2Radius
	vr.sss2_radius_texture = orig_mtl.texmapSss2Radius
	vr.sss2_radius_texture_on = orig_mtl.texmapOnSss2Radius
	vr.sss2_radius_texture_multiplier = orig_mtl.mapamountSss2Radius

	--SSS3
	vr.sss3_color = orig_mtl.sss3Color
	vr.sss3_color_texture = orig_mtl.texmapSss3Color
	vr.sss3_color_texture_on = orig_mtl.texmapOnSss3Color
	vr.sss3_color_texture_multiplier = orig_mtl.mapamountSss3Color
	vr.sss3_weight = orig_mtl.sss3Weight
	vr.sss3_weight_texture = orig_mtl.texmapSss3Weight
	vr.sss3_weight_texture_on = orig_mtl.texmapOnSss3Weight
	vr.sss3_weight_texture_multiplier = orig_mtl.mapamountSss3Weight
	vr.sss3_radius = orig_mtl.sss3Radius
	vr.sss3_radius_texture = orig_mtl.texmapSss3Radius
	vr.sss3_radius_texture_on = orig_mtl.texmapOnSss3Radius
	vr.sss3_radius_texture_multiplier = orig_mtl.mapamountSss3Radius

	--Reflection1
	vr.reflect1_color = orig_mtl.reflection1Color
	vr.reflect1_color_texture = orig_mtl.texmapReflection1Color
	vr.reflect1_color_texture_on = orig_mtl.texmapOnReflection1Color
	vr.reflect1_color_texture_multiplier = orig_mtl.mapamountReflection1Color
	vr.reflect1_strength = orig_mtl.reflection1Level
	vr.reflect1_roughness = 1 - orig_mtl.reflection1Glossiness
	if (orig_mtl.texmapReflection1Glossiness != undefined) do (
		outRefl1RoughTex = output()
		outRefl1RoughTex.map1 = orig_mtl.texmapReflection1Glossiness
		outRefl1RoughTex.output.invert = on
		vr.reflect1_roughness_texture = outRefl1RoughTex
		vr.reflect1_roughness_texture_on = orig_mtl.texmapOnReflection1Glossiness
		vr.reflect1_roughness_texture_multiplier = orig_mtl.mapamountReflection1Glossiness
	)
	vr.reflect1_ior = orig_mtl.reflection1Ior
	vr.reflect1_ior_texture = orig_mtl.texmapReflection1Ior
	vr.reflect1_ior_texture_on = orig_mtl.texmapOnReflection1Ior
	vr.reflect1_ior_texture_multiplier = orig_mtl.mapamountReflection1Ior

	--Reflection2
	vr.reflect2_color = orig_mtl.reflection2Color
	vr.reflect2_color_texture = orig_mtl.texmapReflection2Color
	vr.reflect2_color_texture_on = orig_mtl.texmapOnReflection2Color
	vr.reflect2_color_texture_multiplier = orig_mtl.mapamountReflection2Color
	vr.reflect2_strength = orig_mtl.reflection2Level
	vr.reflect2_roughness = 1 - orig_mtl.reflection2Glossiness
	if (orig_mtl.texmapReflection2Glossiness != undefined) do (
		outRefl2RoughTex = output()
		outRefl2RoughTex.map1 = orig_mtl.texmapReflection2Glossiness
		outRefl2RoughTex.output.invert = on
		vr.reflect2_roughness_texture = outRefl2RoughTex
		vr.reflect2_roughness_texture_on = orig_mtl.texmapOnReflection2Glossiness
		vr.reflect2_roughness_texture_multiplier = orig_mtl.mapamountReflection2Glossiness
	)
	vr.reflect2_ior = orig_mtl.reflection2Ior
	vr.reflect2_ior_texture = orig_mtl.texmapReflection2Ior
	vr.reflect2_ior_texture_on = orig_mtl.texmapOnReflection2Ior
	vr.reflect2_ior_texture_multiplier = orig_mtl.mapamountReflection2Ior

	vr
)
--**********************************************************************************************************************************
--CORONA PHYSICAL material conversion

	--functions
	----Clamp
	fn clamp val minVal maxVal  =
	(
		if val < minVal then val = minVal
		else if val > maxVal then val = maxVal
		return val
	)

	----remap
	fn remapValue oldVal oldMin oldMax newMin newMax =
	(
		oldRange = oldMax - oldMin
		newRange = newMax - newMin
		newVal = (oldVal / oldRange) * newRange
	)

	----Disney Specular to plain IoR
	fn getIorFromDisney specularValue =
	(
		/*
		const float f0      = max(0.f, specularValue * 0.08f);
		const float divisor = 1.f - sqrt(f0);
		if (divisor <= 0.f) {
			return 3.f;
		}
		return clamp(2.f / divisor - 1.f, 1.f, 3.f);
		*/

		f0 = amax #(0.0 , specularValue * 0.08)
		divisor = 1.0 - sqrt(f0)
		outIoR = if divisor <= 0.0 then 3.0	else (clamp (2.0 / divisor - 1.0) 1.0 3.0)
	)

	fn setupComplexIoR cpm=
	(
		theMap = VRayPluginNodeTex name:"complexIoRTex" plugin:"TexComplexFresnel"
		theMap.n_red = cpm.complexIorNRed
		theMap.n_green = cpm.complexIorNGreen
		theMap.n_blue = cpm.complexIorNBlue
		theMap.k_red = cpm.complexIorKRed
		theMap.k_green = cpm.complexIorKGreen
		theMap.k_blue = cpm.complexIorKBlue

		theMap
	)


	-- @param cpm = Corona physical material
	-- @param vrm = V-Ray material
	-- "Full" mode will use vraycomptex and other such maps to ensure the closest possible conversion result (to factor in amounts and other multipliers we do not have.)
	-- "Simple" will skip all that and just replug the maps, and set their influence.
	fn  convertFrom_CoronaPhysicalMtl cpm mode=
	(
		vrm = vrayMtl name:("_VRB." + cpm.name)

		--material flags
		----Metalness
		isMetal = cpm.metalnessMode as booleanClass --we need this for the complex IoR
		vrm.reflection_metalness = cpm.metalnessMode as float

		----Metalness Texture
		if cpm.metalnessTexmap != undefined do
		(
			isMetal = true
			vrm.texmap_metalness = cpm.metalnessTexmap
		)

		----Thinness
		isThin = cpm.useThinMode
		vrm.refraction_thinWalled = isThin

		----Self Illumination
		/*
		Our material's self-illumination matches color*level for lights when the level is expressed in *scene units*.
		Their materials match color*level for lights when the level is expressed in *Radiance*.
		However, when they render our lights, they take the scene units multiplier and treat it straight as if it was radiance.
		The selfillum level should be rechecked!
		*/
		vrm.selfIllumination_multiplier = cpm.selfIllumLevel
		vrm.selfIllumination = cpm.selfIllumColor
		vrm.texmap_self_illumination = cpm.selfIllumTexmap

		----gBuffer channel
		vrm.effectsChannel = if cpm.gBufferOverride >= 0 then cpm.gBufferOverride else cpm.effectsChannel -- -1 uses the normal gbuffer id, anything else overrides it.

		----Alpha mode
		----ours is automatic

		----propagate masks
		case cpm.renderElementPropagation of
		(
			0 :()
			1 :
			(
				vrm.reflection_affectAlpha = 2
			)
			2 :
			(
				vrm.refraction_affectAlpha = 2
			)
			3 :
			(
				vrm.reflection_affectAlpha = 2
				vrm.refraction_affectAlpha = 2
			)
		)

		----Roughness/Glossiness
		isRough = not (cpm.roughnessMode as booleanClass)
		vrm.brdf_useRoughness = isRough  --boolean

		----Specular Mode and IoR
		isDisney = cpm.iorMode as booleanClass --0 is default, 1 is disney.
		if isDisney then
		(
			vrm.refraction_ior = getIorFromDisney cpm.baseIor
		)
		else
		(
			vrm.refraction_ior = cpm.baseIor
		)

		---- Complex IoR
		if isMetal and cpm.useComplexIor do
		(
			vrm.texmap_reflection = setupComplexIoR cpm
			vrm.reflection_fresnel = off
		)

		--Shading Layers
		----Base Color
		if mode == "full" then
		(
			if cpm.baseLevel == 1.0 then --no base level is set, no need for composite maps.
			(
				vrm.diffuse =  cpm.basecolor --this is always true, regardless of metallicity.
				vrm.texmap_diffuse = cpm.baseTexmap --always copy this one. Metals will override it as needed (f.e. with complex IoR)
				if isMetal then
				(
					vrm.reflection = cpm.edgeColor
					if vrm.texmap_reflection == undefined do vrm.texmap_reflection = cpm.edgeColorTexmap --if complex IoR was set, we don't want to override the texture.
					vrm.texmap_reflection_multiplier = cpm.edgeColorMapAmount
					vrm.refraction_ior = 1.6 --Vlado's suggestion.
				)
				else
				(
					vrm.reflection = white
					vrm.refraction_ior = cpm.baseIor
					vrm.texmap_refractionIOR= cpm.baseIorTexmap
				)
			)
			else --the value is lower than 1.0, we need output maps to fix this.
			(
				vrm.diffuse = cpm.basecolor*cpm.baseLevel --this is always true, regardless of metallicity.
				if cpm.baseTexmap!= undefined do
				(
					vrm.texmap_diffuse = output map1:cpm.baseTexmap name:"Base Level Explicitation"
					vrm.texmap_diffuse.output.RGB_Level = cpm.baseLevel
				)
				if isMetal then
				(
					vrm.reflection = cpm.edgeColor*cpm.baseLevel
					if vrm.texmap_reflection == undefined and cpm.edgeColorTexmap != undefined do
					(
						vrm.texmap_reflection = output map1:cpm.edgeColorTexmap name:"Base Level Explicitation"
						vrm.texmap_reflection.output.RGB_Level = cpm.baseLevel
					)
					vrm.texmap_reflection_multiplier = cpm.edgeColorMapAmount
					vrm.refraction_ior = 1.6 --Vlado's suggestion.
				)
				else
				(
					vrm.reflection = white * cpm.baseLevel -- Convert to gray baseLevel color
					vrm.refraction_ior = cpm.baseIor
					vrm.texmap_refractionIOR= cpm.baseIorTexmap
				)
			)
		)
		else --mode is "simple"
		(
			vrm.diffuse =  cpm.basecolor --this is always true, regardless of metallicity.
			vrm.texmap_diffuse = cpm.baseTexmap --always copy this one. Metals will override it as needed (f.e. with complex IoR)
			if isMetal then
			(
				vrm.reflection = cpm.edgeColor
				if vrm.texmap_reflection == undefined do vrm.texmap_reflection = cpm.edgeColorTexmap --if complex IoR was set, we don't want to override the texture.
				vrm.texmap_reflection_multiplier = cpm.edgeColorMapAmount
				vrm.refraction_ior = 1.6 --Vlado's suggestion.
			)
			else
			(
				vrm.reflection = white
				vrm.refraction_ior = cpm.baseIor
				vrm.texmap_refractionIOR= cpm.baseIorTexmap
			)
		)

		----Base Roughness
		vrm.reflection_glossiness = cpm.baseRoughness --the V-Ray material is already set to use the right mode.
		vrm.texmap_reflectionGlossiness = cpm.baseRoughnessTexmap
		vrm.refraction_glossiness = cpm.baseRoughness
		vrm.texmap_refractionGlossiness = cpm.baseRoughnessTexmap

		----Base Bump
		vrm.texmap_bump_multiplier = remapValue cpm.baseBumpMapAmount -99. 99. -1000. 1000.
		vrm.texmap_bump = cpm.baseBumpTexmap

		----Base Anisotropy
		vrm.anisotropy = cpm.baseAnisotropy
		vrm.texmap_anisotropy = cpm.baseAnisotropyTexmap
		vrm.anisotropy_rotation = cpm.baseAnisoRotation + 90
		vrm.texmap_anisotropy_rotation = cpm.baseAnisoRotationTexmap
		vrm.anisotropy_derivation = cpm.anisotropyOrientationMode
		vrm.anisotropy_channel = cpm.anisotropyOrientationUvwChannel

		----Base Translucency
		if isThin and cpm.translucencyFraction > 0.0 do
		(

			vrm.translucency_on = 6
			vrm.translucency_amount = cpm.translucencyFraction
			vrm.translucency_color = cpm.translucencyColor
			if cpm.translucencyFractionTexmap != undefined and mode == "full" then --mapped translucency amount, make explicit multiplying by translucency texture
			(
				vrm.texmap_translucent = vrayCompTex name:"textured translucency fraction explicitation" sourceA:cpm.translucencyColorTexmap sourceB:cpm.translucencyFractionTexmap operator:3
			)
			else
			(
				vrm.texmap_translucent = cpm.translucencyColorTexmap --no map, no worry.
			)
			vrm.texmap_translucent_multiplier = cpm.translucencyColorMapAmount --as this control is reused on our side, the map amount has to be set where the effect is active
			vrm.texmap_translucent_on = cpm.translucencyColorTexmapOn
		)

		----Refraction
		vrm.refraction = white * cpm.refractionAmount -- Convert to gray reflectionAmount color
		if cpm.refractionAmountTexmap != undefined and cpm.refractionAmountTexmapOn do vrm.texmap_refraction = rgb_tint map1:cpm.refractionAmountTexmap red:white green:white blue:white name:"refraction amount texture mono transform"
		vrm.refraction_affectShadows = not cpm.useCaustics
		vrm.refraction_dispersion_on = cpm.dispersionEnable
		vrm.refraction_dispersion = cpm.dispersion

		----Thin Absorption
		if isThin do
		(
			vrm.refraction_fogColor = cpm.thinAbsorptionColor
			vrm.texmap_refraction_fog = cpm.thinAbsorptionTexmap
			vrm.texmap_refraction_fog_multiplier = cpm.thinAbsorptionMapAmount
			vrm.texmap_refraction_fog_on = cpm.thinAbsorptionTexmapOn
		)

		----Opacity
		if cpm.opacityColor != white do --as we don't have a color, but just a texture, i need to do liek below.
		(
			vrm.texmap_opacity = vrayColor color:cpm.opacityColor name:"Opacity Color" rgb_multiplier:cpm.opacityLevel
		)
		if cpm.opacityTexmap != undefined do --i need this to cater for the opacity level, separate from the opacity map amount.
		(
			if mode == "full" then
			(
				vrmColorMap = vrayColor color:cpm.opacityColor name:"Opacity Color" rgb_multiplier:cpm.opacityLevel
				vrm.texmap_opacity = vrayCompTex sourceA:vrmColorMap sourceB:cpm.opacityTexmap operator:3 multiplier:(cpm.opacityMapAmount/100.0)
			)
			else --mode is "simple"
			(
				vrm.texmap_opacity = cpm.opacityTexmap
				vrm.texmap_opacity_multiplier = cpm.opacityMapAmount
			)
		)
		if cpm.opacityCutout do vrm.option_opacityMode = 1

		----Displacement
		----I'll only plug the texture as the rest of the settings aren't present on the v-ray material
		----No map influence for the CPM.
		vrm.texmap_displacement = cpm.displacementTexmap

		----Clearcoat
		vrm.coat_amount = cpm.clearcoatAmount

		vrm.texmap_coat_amount = cpm.clearcoatAmountTexmap
		vrm.coat_glossiness = cpm.clearcoatRoughness --this is properly set to rough/gloss at the top for the whole shader, pipe 1:1
		vrm.texmap_coat_glossiness = cpm.clearcoatRoughnessTexmap
		vrm.coat_ior = cpm.clearcoatIor
		vrm.texmap_coat_ior = cpm.clearcoatIorTexmap
		vrm.coat_color = cpm.clearcoatAbsorptionColor
		vrm.texmap_coat_color = cpm.clearcoatAbsorptionTexmap
		vrm.texmap_coat_bump_multiplier = remapValue cpm.clearcoatBumpMapAmount -99. 99. -1000. 1000. --this hasn't got an Ui in the right place for the corona material. so odd.
		vrm.texmap_coat_bump = cpm.clearcoatBumpTexmap


		----Sheen
		/*
		Sheen has an amount and a textured amount, which we lack.
		*/

		if mode == "full" and ((cpm.sheenAmount > 0.0 and cpm.sheenAmount < 1.0) or cpm.sheenAmountTexmap != undefined) then --influence lower than 1.0, and/or textured influence, need output maps
		(
			if cpm.sheenAmountTexmap == undefined then --just the level, this is doable with outputs.
			(
				vrm.sheen_color = cpm.sheenColor * cpm.sheenAmount
				if cpm.sheenColorTexmap != undefined do
				(
					vrm.texmap_sheen = output map1:cpm.sheenColorTexmap name:"Sheen Amount Explicitation"
					vrm.texmap_sheen.output.rgb_level = cpm.sheenAmount
					vrm.texmap_sheen_multiplier = cpm.sheenColorMapAmount
				)
			)
			else --we have a texture driving amount, need a comptex
			(
				sheenAmountMap = vrayColor color:white rgb_multiplier:cpm.sheenAmount --made the float amount a color.
				monoAmountMap =  rgb_tint map1:cpm.sheenAmountTexmap red:white green:white blue:white name:"Sheen amount texture mono transform"
				globalSheenAmountMap = vrayCompTex name:"globalSheenAmountMap" sourceA:sheenAmountMap sourceB:monoAmountMap operator:3
				globalSheenAmountMap.multiplier=(cpm.sheenAmountMapAmount/100.)
				sheenColorMap = vrayColor color:cpm.sheenColor

				if cpm.sheenColorTexmap != undefined then --
				(
					sheenTexturedColour = vrayCompTex name:"textured Sheen amount explicitation" sourceA:sheenColorMap sourceB:cpm.sheenColorTexmap operator:9 multiplier:(cpm.sheenColorMapAmount/100.)
					vrm.texmap_sheen = vrayCompTex name:"globalSheenColorMap" sourceA:sheenTexturedColour sourceB:globalSheenAmountMap operator:3
				)
				else
				(
					texturedAmount = vrayCompTex name:"textured Sheen amount explicitation" sourceA:sheenColorMap sourceB:monoMap operator:3
					texturedAmount.multiplier=(cpm.sheenColorMapAmount/100.) --oddly it's 0-1 while the UI shows 0-100
					vrm.texmap_sheen = texturedAmount
				)
			)
		)
		else --influence at 1.0, or we chose simple mode. we can just plug away.
		(
			vrm.sheen_color = cpm.sheenColor * cpm.sheenAmount
			vrm.texmap_sheen = cpm.sheenColorTexmap
			vrm.texmap_sheen_multiplier = cpm.sheenColorMapAmount
		)
		vrm.sheen_glossiness = cpm.sheenRoughness
		vrm.texmap_sheen_glossiness = cpm.sheenRoughnessTexmap

		----Fog
		vrm.refraction_fogColor = cpm.volumetricAbsorptionColor
		vrm.texmap_refraction_fog = cpm.volumetricAbsorptionTexmap
		vrm.texmap_refraction_fog_multiplier = cpm.volumetricAbsorptionMapAmount
		vrm.texmap_refraction_fog_on = cpm.volumetricAbsorptionTexmapOn
		vrm.refraction_fogDepth = cpm.attenuationDistance

		----Volumetric Scattering
		if cpm.volumetricScatteringColor != black or cpm.volumetricScatteringTexmap != undefined do
		(
			vrm.translucency_on = 5 --vol. scatter
			vrm.translucency_color = cpm.volumetricScatteringColor
			vrm.texmap_translucent = cpm.volumetricScatteringTexmap
			vrm.texmap_translucent_multiplier = cpm.volumetricScatteringMapAmount
			vrm.texmap_translucent_on = cpm.volumetricScatteringTexmapOn
		)

		----SSS
		if cpm.sssAmount > 0.0 or cpm.sssAmountTexmap != undefined do
		(
			vrm.translucency_on = 6 --SSS
			vrm.translucency_amount = cpm.sssAmount
			vrm.translucency_color = cpm.sssScatterColor
			if mode == "full" and (cpm.sssAmountTexmap != undefined and cpm.sssAmountTexmapOn) then --textured influence. Make explicit.
			(
				monoMap = rgb_tint map1:cpm.sssAmountTexmap red:white green:white blue:white name:"SSS amount texture mono transform"
				vrm.texmap_translucent = vrayCompTex name:"textured SSS amount explicitation" sourceA:monoMap sourceB:cpm.sssScatterTexmap operator:3
				vrm.texmap_translucent_multiplier = cpm.sssScatterMapAmount
				vrm.texmap_translucent_on = cpm.sssScatterTexmapOn --troublesome, as the map is explicitated above.
			)
			else --mode is "simple", or no textured influence
			(
				vrm.texmap_translucent = cpm.sssScatterTexmap --no map, no worry.
				vrm.texmap_translucent_multiplier = cpm.sssScatterMapAmount
				vrm.texmap_translucent_on =	cpm.sssScatterTexmapOn
			)
			vrm.refraction_fogDepth = cpm.sssRadius * 100
			if cpm.sssRadiusTexmap != undefined and cpm.sssRadiusTexmapOn do
			(
				vrm.texmap_refraction_fog = output map1:cpm.sssRadiusTexmap name:"SSS Radiut units conversion"
				vrm.texmap_refraction_fog.output.RGB_Level = 1
				vrm.texmap_refraction_fog_multiplier = cpm.sssRadiusMapAmount
				vrm.texmap_refraction_fog_on = cpm.sssRadiusTexmapOn
			)
		)

		--extra maps
		----Environment: i plug the refraction one first, and the reflection one then, so to give it higher priority.
		----As we only have one slot, this ensures the reflection one is the one that will be chosen if both are plugged in the CPM.
		vrm.texmap_environment = cpm.bgOverrideRefractTexmap
		vrm.texmap_environment = cpm.bgOverrideReflectTexmap

		--Unconditional Map Influences
		vrm.texmap_diffuse_multiplier = cpm.baseMapAmount
		vrm.texmap_reflectionGlossiness_multiplier = cpm.baseRoughnessMapAmount
		vrm.texmap_refraction_multiplier = cpm.refractionAmountMapAmount

		vrm.texmap_self_illumination_multiplier = cpm.selfillumMapAmount
		vrm.texmap_anisotropy_multiplier = cpm.baseAnisotropyMapAmount
		vrm.texmap_anisotropy_rotation_multiplier = cpm.baseAnisoRotationMapAmount
		vrm.texmap_refractionIOR_multiplier = cpm.baseIorMapAmount
		vrm.texmap_coat_amount_multiplier = cpm.clearcoatAmountMapAmount
		vrm.texmap_coat_ior_multiplier = cpm.clearcoatIorMapAmount
		vrm.texmap_coat_color_multiplier = cpm.clearcoatAbsorptionMapAmount
		vrm.texmap_coat_glossiness_multiplier = cpm.clearcoatRoughnessMapAmount
		vrm.texmap_sheen_glossiness_multiplier = cpm.sheenRoughnessMapAmount

		--Unconditional Map Toggles
		vrm.texmap_diffuse_on = cpm.baseTexmapOn
		vrm.texmap_reflection_on = cpm.edgeColorTexmapOn
		vrm.texmap_reflectionGlossiness_on = cpm.baseRoughnessTexmapOn
		vrm.texmap_bump_on = cpm.baseBumpTexmapOn
		vrm.texmap_opacity_on = cpm.opacityTexmapOn
		vrm.texmap_displacement_on = cpm.displacementTexmapOn
		vrm.texmap_self_illumination_on = cpm.selfIllumTexmapOn
		vrm.texmap_metalness_on = cpm.metalnessTexmapOn
		vrm.texmap_anisotropy_on = cpm.baseAnisotropyTexmapOn
		vrm.texmap_anisotropy_rotation_on = cpm.baseAnisoRotationTexmapOn
		vrm.texmap_refractionIOR_on = cpm.baseIorTexmapOn
		vrm.texmap_coat_amount_on = cpm.clearcoatAmountTexmapOn
		vrm.texmap_coat_glossiness_on = cpm.clearcoatRoughnessTexmapOn
		vrm.texmap_coat_ior_on = cpm.clearcoatIorTexmapOn
		vrm.texmap_coat_color_on = cpm.clearcoatAbsorptionTexmapOn
		vrm.texmap_coat_bump_on = cpm.clearcoatBumpTexmapOn
		vrm.texmap_sheen_on = cpm.sheenColorTexmapOn
		vrm.texmap_sheen_glossiness_on = cpm.sheenRoughnessTexmapOn
		vrm.texmap_environment_on = cpm.bgOverrideReflectTexmapOn or cpm.bgOverrideRefractTexmapOn

		--V-Ray material output
		vrm
	)
--**********************************************************************************************************************************

fn convertFrom_CoronaColorTex inTexture = (
	vrayC = VRayColor name:("_VRB."+inTexture.name) alpha:inTexture.alpha rgb_multiplier: inTexture.multiplier
	if inTexture.method == 0 do (
		vrayC.color_mode = 0
		vrayC.color = inTexture.color
	)
	if inTexture.method == 1 do (
		vrayC.color_mode = 0
		vrayC.red = inTexture.colorHdr[1]
		vrayC.green = inTexture.colorHdr[2]
		vrayC.blue = inTexture.colorHdr[3]
	)
	if inTexture.method == 2 do (
		vrayC.color_mode = 1
		vrayC.temperature = inTexture.temperature
	)
	if inTexture.method == 3 do (
		vrayC.color_mode = 0
		local strHexColor = inTexture.hexColor
		if (strHexColor.count == 6 or strHexColor.count == 7) then (
			local startVal = 1
			if ((findString strHexColor "#") == 1) do startVal = 2

			local subStrHexColor = "0x" + (substring strHexColor startVal 2)
			local rColor = (subStrHexColor as float)
			startVal = startVal +2
			subStrHexColor = "0x" + (substring strHexColor startVal 2)
			local gColor = (subStrHexColor as float)
			startVal = startVal +2
			subStrHexColor = "0x" + (substring strHexColor startVal 2)
			local bColor = (subStrHexColor as float)

			if (rColor!=undefined and gColor!=undefined and bColor!=undefined) then (
				vrayC.color = (color rColor gColor bColor)
			) else (
				vrayC.color = (color 0.0f 0.0f 0.0f)
			)
		) else (
			vrayC.color = (color 255.0f 0.0f 0.0f)
		)
	)
	return  vrayC
)

fn convertFrom_CoronaMultiMapTex inTexture = (
	vrayMST = VRayMultiSubTex name:("_VRB."+inTexture.name)
	if vrayMST.texmap_num > inTexture.items do (
		local removeItems = vrayMST.texmap_num - inTexture.items
		vrayMST.deleteSubtex (inTexture.items + 1) removeItems
	)

	if vrayMST.texmap_num < inTexture.items do (
		local addItems = inTexture.items - vrayMST.texmap_num
		vrayMST.addSubtex addItems
	)

	-- 3DGROUND Edition
	try (if inTexture.mode == 5 do vrayMST.from_id = 1) catch ()
	try (if inTexture.mode == 2 do vrayMST.from_id = 6) catch ()

	for i = 1 to inTexture.items do (
		vrayMST.texmap_color[i] = inTexture.colors[i]
		vrayMST.texmap[i] = inTexture.texmaps[i]
	)

	return vrayMST
)

fn convertFrom_CoronaMixTex inTexture = (
	vrayCT = VRayCompTex sourceA: inTexture.texmapBottom sourceB: inTexture.texmapTop name:("_VRB."+inTexture.name)
	vrayCT.operator = case inTexture.mixOperation of (
		0: 0 -- Add
		1: 1 -- subtract
		2: 3 -- multiply
		3: 4 -- divide
		4: 5 -- minimum
		5: 6 -- maximum
		8: 2 -- difference
		default:0
		)
	return vrayCT
)

-- !!! MastaMan Edition
fn convertFrom_CoronaFrontBackTex inTexture = (
	if (inTexture.frontTexmap != undefined) do (
		return inTexture.frontTexmap
	)
	vrayClr = VRayColor color:inTexture.frontColor name:("_VRB."+inTexture.name)
	return vrayClr	
)

fn convertFrom_CoronaAoTex inTexture = (
	vrayDt = VRayDirt occluded_color:inTexture.colorOccluded unoccluded_color:inTexture.colorUnoccluded \
	radius:inTexture.maxDistance texmap_radius:inTexture.texmapDistance texmap_occluded_color:inTexture.texmapOccluded \
	texmap_unoccluded_color:inTexture.texmapUnoccluded name:("_VRB."+inTexture.name)

	if (hasProperty inTexture "invert") then (
		vrayDt.invert_normal = inTexture.invert
	)
	else if (hasProperty inTexture "normalMode") then (
		vrayDt.invert_normal = case of (
			(inTexture.normalMode == 0):false
			(inTexture.normalMode == 1):true
			(inTexture.normalMode == 2):false
			default:false)
	)

	---!!! MastaMan edition (commented)
	if inTexture.occlusionFrom == 1 and inTexture.excludeList.count != 0 do vrayDt.excludeList = inTexture.excludeList
	if inTexture.occlusionFrom == 3 do vrayDt.consider_same_object_only = true

	vrayDt.texmap_radius = if inTexture.texmapDistance != undefined do inTexture.texmapDistance
	vrayDt.texmap_occluded_color = if inTexture.texmapOccluded != undefined do inTexture.texmapOccluded
	vrayDt.texmap_unoccluded_color = if inTexture.texmapUnoccluded != undefined do inTexture.texmapUnoccluded

	return vrayDt
)

fn convertFrom_CoronaNormalTex inTexture = (
	vrayNM = VRayNormalMap normal_map:inTexture.normalMap name:("_VRB."+inTexture.name)

	if ((hasProperty vrayNM #flip_red) and
	    (hasProperty inTexture #flipred)) then (
			vrayNM.flip_red = inTexture.flipred
			vrayNM.flip_green = inTexture.flipgreen
			vrayNM.swap_red_and_green = inTexture.swapRedGreen
	)

	if ((hasProperty vrayNM #bump_map) and -- Vray 3.3
		(hasProperty inTexture #additionalBump)) then (
		vrayNM.bump_map = inTexture.additionalBump
		if vrayNM.bump_map != undefined do (
			vrayNM.bump_map_on = inTexture.additionalBumpOn
			vrayNM.bump_map_multiplier = inTexture.additionalBumpStrength
		)
	)

	if (hasProperty vrayNM #apply_gamma) then (
		vrayNM.apply_gamma = inTexture.addGamma
	)

	return vrayNM
)

fn convertFrom_CoronaRoundEdges inTexture = (
	---!!! MastaMan edition (param false)
	vrRoundEdges = VRayEdgesTex name:("_VRB."+inTexture.name) roundedCorners_radius:inTexture.radius \	
	roundedCorners_sameObjectOnly:(inTexture.occlusionFrom == 1)
)

fn convertFrom_CoronaDistance inTexture = (
	vrDistTex = VRayDistanceTex  name:("_VRB."+inTexture.name)

	vrDistTex.objects = inTexture.nodes
	vrDistTex.texmap_far_on = inTexture.texmapFarOn
	vrDistTex.far_color = inTexture.colorFar
	vrDistTex.texmap_far = inTexture.texmapFar
	vrDistTex.texmap_near_on = inTexture.texmapNearOn
	vrDistTex.near_color = inTexture.colorNear
	vrDistTex.texmap_near = inTexture.texmapNear
	vrDistTex.distance = inTexture.distanceFar
	vrDistTex.tex_inside_separate_on = inTexture.useInside
	vrDistTex.texmap_distance_on = inTexture.distanceScaleTexmapOn
	vrDistTex.texmap_distance = inTexture.distanceScaleTexmap

	if (inTexture.useInside == on) then (
		vrDistTex.inside_color = inTexture.colorInside
		vrDistTex.texmap_inside = inTexture.texmapInside
		vrDistTex.texmap_inside_on = inTexture.texmapInsideOn
	)

	vrDistTex
)

fn convertFrom_CoronaTriplanar inTexture = (
	vrTriplanarTex = VRayTriplanarTex name:("_VRB."+inTexture.name)

	vrTriplanarTex.texture_mode = if inTexture.onlyTexmapX == on then 0 else 1

	if inTexture.texmapX !=undefined and inTexture.texmapXOn == on then
		vrTriplanarTex.texture = inTexture.texmapX
	if inTexture.texmapY !=undefined and inTexture.texmapYOn == on then
		vrTriplanarTex.texture_y = inTexture.texmapY
	if inTexture.texmapZ !=undefined and inTexture.texmapZOn == on then
		vrTriplanarTex.texture_z = inTexture.texmapZ

	vrTriplanarTex.size = inTexture.scale
	vrTriplanarTex.blend = inTexture.blend

	case inTexture.space of (
		0: (
			vrTriplanarTex.space = 0
		)
		1: (
			vrTriplanarTex.space = 1
			vrTriplanarTex.reference_node = undefined
		)
		2: (
			vrTriplanarTex.space = 1
			vrTriplanarTex.reference_node = inTexture.referenceNode
		)
	)
	vrTriplanarTex.frame_offset = inTexture.offset
	vrTriplanarTex.texture_rotation = inTexture.rotation

	vrTriplanarTex
)

fn convertFrom_CoronaBitmap inTexture = (
	local texHDRI=VRayBitmap()
	texHDRI.name="_VRB."+inTexture.name

	if inTexture.filename != "" and inTexture.filename != undefined then (
		texHDRI.HDRIMapName = inTexture.filename
	)

	--Corona Bitmap -> Environment mode 4: MirrorBall,  corresponds to
	--VRay Bitmap -> Mapping type 3: Mirrored ball
	if inTexture.enviroMapping == 4 then texHDRI.mapType = 3

	--Corona Bitmap -> Environment mode 0: Spherical
	--VRay Bitmap -> Mapping type 4: 3ds Max standard
	if inTexture.enviroMapping == 0 then (
		texHDRI.mapType = 4 --3ds Max standard
		if environmentMap == inTexture then
			texHDRI.coords.mappingType = 1 -- Coordinates -> Environ
		else
			texHDRI.coords.mappingType = 0 -- Coordinates -> Texture
		texHDRI.coords.mapping = 0 -- Coordinates -> Spherical Environment
	)

	case inTexture.interpolation of (
		0: (texHDRI.interpType = 0; texHDRI.filterMode = 0)
		1: (texHDRI.interpType = 1; texHDRI.filterMode = 0)
		2: texHDRI.filterMode = 1
	)

	-- Gamma handling
	-- Set this after setting HDRIMapName so as to override any automatic gamma detection in VRayBitmap
	if (maxversion())[1] >= 16000 and inTexture.gamma != -1 then(
		texHDRI.color_space = 1 -- Inverse gamma
		texHDRI.gamma = 1.0/inTexture.gamma
	) else (
		texHDRI.color_space = 3 -- Automatic gamma
	)

	-- uv channel, environment mode
	if texHDRI.coords.mappingType==0 and inTexture.uvwChannel == 0 then (
		texHDRI.coords.mapping = 1
	)else(
		texHDRI.coords.mapChannel = inTexture.uvwChannel
	)

	-- offset, tiling/scale, rotation, rw mapscale
	texHDRI.coords.realWorldScale = inTexture.realWorldScale

	texHDRI.coords.U_Offset = inTexture.uvwOffset[1]
	texHDRI.coords.V_Offset = inTexture.uvwOffset[2]

	if inTexture.realWorldScale then (
		texHDRI.coords.realWorldWidth = inTexture.uvwScale[1]
		texHDRI.coords.realWorldHeight = inTexture.uvwScale[2]
	)else(
		texHDRI.coords.U_Tiling = inTexture.uvwScale[1]
		texHDRI.coords.V_Tiling = inTexture.uvwScale[2]
	)

	case inTexture.tilingU of (
		0: (texHDRI.coords.U_Mirror = false; texHDRI.coords.U_Tile = false)
		2: (texHDRI.coords.U_Mirror = true; texHDRI.coords.U_Tile = false)
		1: (texHDRI.coords.U_Mirror = false; texHDRI.coords.U_Tile = true)
	)
	case inTexture.tilingV of (
		0: (texHDRI.coords.V_Mirror = false; texHDRI.coords.V_Tile = false)
		2: (texHDRI.coords.V_Mirror = true; texHDRI.coords.V_Tile = false)
		1: (texHDRI.coords.V_Mirror = false; texHDRI.coords.V_Tile = true)
	)
	texHDRI.coords.W_angle = inTexture.wAngle
	if environmentMap == inTexture then (
		texHDRI.coords.W_angle *= -1.0f
	)

	-- crop/place
	texHDRI.cropplace_on = inTexture.clippingOn
	texHDRI.cropplace_mode = inTexture.clippingMode
	texHDRI.cropplace_u = inTexture.clippingU
	texHDRI.cropplace_v = inTexture.clippingV
	texHDRI.cropplace_width = inTexture.clippingWidth
	texHDRI.cropplace_height = inTexture.clippingHeight

	-- alpha source, mono channel out, rgb channel out
	texHDRI.alphaSource = inTexture.alphaSource
	texHDRI.monoOutput = inTexture.monoChannelOutput
	texHDRI.rgbOutput = inTexture.rgbChannelOutput

	texHDRI.coords.blur = inTexture.filteringBlur

	--Convert output parameters including curve control
	replaceInstances texHDRI.output (copy inTexture.output)

	texHDRI
)

fn convertFrom_CoronaBumpConverter inTexture = (
	local vrColor2BumpTex = VRayColor2Bump name:("_VRB."+inTexture.name)
	vrColor2BumpTex.map = inTexture.input

	vrColor2BumpTex
)

-- Function used in conversion from CoronaColorCorrect to Color_Correction
-- when 'controlsSource' is set to 1 ->'Use settings from map: '. That means
-- settings from another <set to 'copiedMap' parameter> CoronaColorCorrect
-- map will be used. The function helps to reach the base map which settings are used.
fn getTexSettingsBase inTex = (
	if ((inTex != undefined) and (hasProperty inTex "controlsSource") and (hasProperty inTex "copiedMap")) do (
		local texSettings = inTex
		if inTex.controlsSource == 1 do ( -- 'Use settings from map'
			texSettings = getTexSettingsBase inTex.copiedMap
		)
		return texSettings
	)
	undefined
)

fn convertFrom_CoronaColorCorrect inTexture = (
	local colorCorrectionTex = Color_Correction name:("_VRB."+inTexture.name)
	colorCorrectionTex.map = inTexture.inputTexmap

	-- Get base map which settings will be used
	local texSettings = getTexSettingsBase inTexture
	if texSettings != undefined then ( -- 'Use these settings:' option in CoronaColorCorrect
		colorCorrectionTex.hueShift = texSettings.hue
		colorCorrectionTex.saturation = texSettings.saturation
		colorCorrectionTex.lightnessMode=1 -- Lightness advanced mode
		-- Additional correctons for brightness and contrast
		colorCorrectionTex.liftRGB = texSettings.brightness
		colorCorrectionTex.gammaRGB = (texSettings.gamma + texSettings.contrast)/2 - 0.5f
		if colorCorrectionTex.gammaRGB >1 do (
			colorCorrectionTex.gammaRGB = colorCorrectionTex.gammaRGB/10.0f
			colorCorrectionTex.gammaRGB = colorCorrectionTex.gammaRGB  + 0.5f
		)

		if texSettings.invert == on do colorCorrectionTex.rewireMode = 2 -- Channels->Invert
		if texSettings.lutEnable == true and texSettings.lutFile != undefined then (
			local vrayLUTTex = VRayLUT()
			colorCorrectionTex.gammaRGB = colorCorrectionTex.gammaRGB - 0.5f
			vrayLUTTex.use_logspace = texSettings.lutLog
			if vrayLUTTex.use_logspace == on then (
				colorCorrectionTex.gammaRGB = colorCorrectionTex.gammaRGB +1.0f
			)
			vrayLUTTex.basemap = colorCorrectionTex
			vrayLUTTex.lutFile = texSettings.lutFile
			return vrayLUTTex
		)
	)
	colorCorrectionTex
)

fn convertFrom_AutodeskBitmap texmap=(
	if (texmap!=undefined and (classof texmap)==Autodesk_Map) then (
		local texHDRI=VRayBitmap()
		texHDRI.name="_VRB."+texmap.name

		if (IsProperty texmap "Parameters_Source") and (undefined != texmap.Parameters_Source) do
		(
			texHDRI.HDRIMapName = texmap.Parameters_Source.filename
		)
		if (IsProperty texmap "Parameters_Brightness") and (undefined != texmap.Parameters_Brightness) do
		(
			texHDRI.output.RGB_Level = texmap.Parameters_Brightness / 100
		)

		if (IsProperty texmap "Parameters_Invert_Image") and (undefined != texmap.Parameters_Invert_Image) do
		(
			texHDRI.output.invert = texmap.Parameters_Invert_Image
		)

		texHDRI.coords.mappingType = 0 --Texture
		texHDRI.coords.mapping = 0 --Explicit Map Channel
		texHDRI.coords.realWorldScale = true

		if (IsProperty texmap "Position_X") and (undefined != texmap.Position_X) do
		(
			texHDRI.UVGen.u_offset = texmap.Position_X
			if(texmap.Position_X.controller != undefined) do texHDRI.UVGen.u_offset = texmap.Position_X.controller
		)

		if (IsProperty texmap "Position_Y") and (undefined != texmap.Position_Y) do
		(
			texHDRI.UVGen.v_offset = texmap.Position_Y
			if(texmap.Position_Y.controller != undefined) do texHDRI.UVGen.v_offset.controller = texmap.Position_Y.controller
		)

		if (IsProperty texmap "Scale_Width") and (undefined != texmap.Scale_Width) do
		(
			texHDRI.UVGen.realWorldWidth = texmap.Scale_Width
			if(texmap.Scale_Width.controller != undefined) do texHDRI.UVGen.realWorldWidth.controller = texmap.Scale_Width.controller
		)

		if (IsProperty texmap "Scale_Height") and (undefined != texmap.Scale_Height) do
		(
			texHDRI.UVGen.realWorldHeight = texmap.Scale_Height
			if(texmap.Scale_Height.controller != undefined) do texHDRI.UVGen.realWorldHeight.controller = texmap.Scale_Height.controller
		)

		--According to the documentation the rotation is done on the Z axis, so rotation is on the W axis
		if (IsProperty texmap "Position_Rotation") and (undefined != texmap.Position_Rotation) do
		(
			texHDRI.UVGen.W_Angle = texmap.Position_Rotation
			if(texmap.Position_Rotation.controller != undefined) do texHDRI.UVGen.W_Angle.controller = texmap.Position_Rotation.controller
		)
		texHDRI.UVGen.V_Angle = 0.0
		texHDRI.UVGen.U_Angle = 0.0

		texHDRI.UVGen.U_Mirror = false
		texHDRI.UVGen.V_Mirror = false
		if (IsProperty texmap "Repeat_Horizontal") and (undefined != texmap.Repeat_Horizontal) do
		(
			texHDRI.UVGen.U_Tile = texmap.Repeat_Horizontal
		)
		if (IsProperty texmap "Repeat_Vertical") and (undefined != texmap.Repeat_Vertical) do
		(
			texHDRI.UVGen.V_Tile = texmap.Repeat_Vertical
		)

		if (IsProperty texmap "Advanced_Parameters_Blur") and (undefined != texmap.Advanced_Parameters_Blur) do
		(
			texHDRI.UVGen.blur = texmap.Advanced_Parameters_Blur
			if(texmap.Advanced_Parameters_Blur.controller != undefined) do texHDRI.UVGen.blur.controller = texmap.Advanced_Parameters_Blur.controller
		)

		if (IsProperty texmap "Advanced_Parameters_Blur_Offset") and (undefined != texmap.Advanced_Parameters_Blur_Offset) do
		(
			texHDRI.UVGen.Blur_Offset = texmap.Advanced_Parameters_Blur_Offset
			if(texmap.Advanced_Parameters_Blur_Offset.controller != undefined) do texHDRI.UVGen.Blur_Offset.controller = texmap.Advanced_Parameters_Blur_Offset.controller
		)

		if (IsProperty texmap "Advanced_Parameters_Map_Channel") and (undefined != texmap.Advanced_Parameters_Map_Channel) do
		(
			texHDRI.UVGen.mapChannel = texmap.Advanced_Parameters_Map_Channel
		)

		texHDRI.mapType=4 /*The mapping type is determined by the Coordinates section.*/
		texHDRI.color_space=3 /*The gamma is controlled from 3ds Max (customize -> preferences -> Gamma and LUT -> Input Gamma)*/

		texHDRI
	)
	else (
		undefined
	)
)

fn convertFrom_RaytraceMap texmap=(
	if (texmap!=undefined and (classof texmap)==Raytrace) then (
		local texVRayColor=VRayColor()
		texVRayColor.name="_VRB."+texmap.name
		texVRayColor.color=(color 0 0 0)

		texVRayColor
	)
	else (
		undefined
	)
)

fn isVRayCompatible mtl_classid = (
	-- native V-Ray materials
	if mtl_classid==VRayMtl then return true
	if mtl_classid==VRay2SidedMtl then return true
	if mtl_classid==VRayBlendMtl then return true
	if mtl_classid==VRayFastSSS then return true
	if mtl_classid==VRayLightMtl then return true
	if mtl_classid==VRayMtlWrapper then return true

	-- supported 3dsmax materials
	if mtl_classid==Multimaterial then return true
	if mtl_classid==Arch___Design__mi then return true

	false
)

fn isVRayCompatibleTex tex_classid = (
	-- native V-Ray textures
	compatibleTexClassIDs = #(VRayBmpFilter, VRayBump2Normal, VRayColor, VRayColor2Bump, VRayCompTex, VRayCurvature, VRayDirt, VRayDistanceTex, VRayEdgesTex, \
										  VRayFakeFresnelTex, VRayGLSLTex, VRayHairInfoTex, VRayBitmap, VRayICC, VRayLut, VRayMap, VRayMultiSubTex, VRayOCIO, VRayOSLTex, \
										  VRayParticleTex, VRayPtex, VRaySamplerInfoTex, VRaySky, VRaySoftbox, VRayTriplanarTex, VRayUserColor, VRayUserScalar)
    result = findItem compatibleTexClassIDs tex_classid
	if result > 0 then return true
	return false
)

fn createVRayTexture inTexture= (
	-- check if this is a texture; if not, just return the value
	if ((superclassof inTexture)!=textureMap) then return inTexture

	-- check if we have already converted this texture; if yes, just return
	-- the already converted one
	local i=findItem orig_texmaps inTexture
	if i>0 then return new_texmaps[i]

	-- recurse into sub-textures, if any
	local sub_count=getNumSubTexmaps inTexture
	if sub_count>0 then (
		local sub_tex = undefined
		for i=1 to sub_count do (
			sub_tex = getSubTexmap inTexture i
			if(sub_tex != undefined) then
				setSubTexmap inTexture i (createVRayTexture sub_tex)
		)
	)

	-- get the texture class id
	cls=classof inTexture

	-- if this is already a V-Ray compatible material, return the same one
	if (isVRayCompatibleTex cls) then return inTexture

	-- try to convert
	format "  %\n" inTexture
	local new_tex=case cls of (
		Normal_Bump: VRayNormalMap name:inTexture.name normal_map:inTexture.normal_map normal_map_on:inTexture.map1on normal_map_multiplier:inTexture.mult_spin \
											bump_map:inTexture.bump_map bump_map_on:inTexture.map2on bump_map_multiplier:inTexture.bump_spin \
											flip_red:inTexture.flipred flip_green:inTexture.flipgreen swap_red_and_green:inTexture.swap_rg
		Autodesk_Map: convertFrom_AutodeskBitmap inTexture
		Raytrace:convertFrom_RaytraceMap inTexture
		CoronaOutput: if inTexture.inputTexmap != undefined do inTexture.inputTexmap
		CoronaRaySwitch: VRayColor color:red name:("_VRB."+inTexture.name)
		-- !!! MastaMan edition
		CoronaFrontBack: convertFrom_CoronaFrontBackTex inTexture --VRayColor color:inTexture.frontColor name:("_VRB."+inTexture.name)
		CoronaColor: convertFrom_CoronaColorTex inTexture
		CoronaMultiMap: convertFrom_CoronaMultiMapTex inTexture
		CoronaMix: convertFrom_CoronaMixTex inTexture
		CoronaAo: convertFrom_CoronaAoTex inTexture
		CoronaNormal: convertFrom_CoronaNormalTex inTexture
		coronasky: VRaySky name:("_VRB."+inTexture.name)
		CoronaWire: VRayEdgesTex edgesColor:inTexture.edgeColor widthType:(if inTexture.widthMode == 1 then 0 else 1) thickness:inTexture.edgeWidthWorld \
											pixelWidth:inTexture.edgeWidthPixels name:("_VRB."+inTexture.name)

		CoronaDistance: convertFrom_CoronaDistance inTexture
		CoronaRoundEdges: convertFrom_CoronaRoundEdges inTexture
		CoronaTriplanar: convertFrom_CoronaTriplanar inTexture
		CoronaBitmap: convertFrom_CoronaBitmap inTexture
		CoronaBumpConverter: convertFrom_CoronaBumpConverter inTexture
		CoronaColorCorrect: convertFrom_CoronaColorCorrect inTexture
		default: inTexture
	)

	-- if converted, add to the list of converted textures
	if new_tex!=inTexture then (
		append orig_texmaps inTexture
		append new_texmaps new_tex
	)

	-- return the new texture
	new_tex
)

--create a node in Slate Material Editor for
--newly creted material/texture on the position of the old one
--the node for objRef is not deleted
fn createSMENodeByRef objRef newObjRef= (
	if (maxver < 13000) do return undefined

	if(objRef != newObjRef) do (
		local numViews = sme.GetNumViews()
		for iView=1 to numViews do (
			local currentView = sme.GetView iView
			local nodeByRef = currentView.GetNodeByRef objRef
			if (nodeByRef != undefined) then (
				currentView.CreateNode newObjRef nodeByRef.position
				break
			)
		)
	)
)

fn createVRayMtl orig_mtl = (
	-- check if this is a material; if not, just return the value
	if ((superclassof orig_mtl)!=material) then return orig_mtl

	-- convert sub-textures of this material
	local sub_texs_count=getNumSubTexmaps orig_mtl
	if sub_texs_count>0 then (
		local sub_tex = undefined
		for i=1 to sub_texs_count do (
			sub_tex = getSubTexmap orig_mtl i
			if(sub_tex != undefined) then
				setSubTexmap orig_mtl i (createVRayTexture sub_tex)
		)
	)

	-- check if we have already converted this material; if yes, just return
	-- the already converted one
	local i=findItem orig_mtls orig_mtl
	if i>0 then return new_mtls[i]

	-- recurse into sub-materials, if any
	local sub_count=getNumSubMtls orig_mtl
	if sub_count>0 then (
		local sub_mtl = undefined
		for i=1 to sub_count do (
			sub_mtl=getSubMtl orig_mtl i
			if(sub_mtl != undefined) then
				setSubMtl orig_mtl i (createVRayMtl sub_mtl)
		)
	)

	-- get the material class id
	cls=classof orig_mtl

	-- if this is already a V-Ray compatible material, return the same one
	if (isVRayCompatible cls) then (
		--If the VRayMtl comes from old scenes with unlocked hilight glossiness
		if cls==VRayMtl and orig_mtl.reflection_lockGlossiness==off then (
			orig_mtl.hilight_glossiness = orig_mtl.reflection_glossiness
			orig_mtl.texmap_hilightGlossiness = undefined
			orig_mtl.reflection_lockGlossiness = on
		)
		return orig_mtl
	)

	-- otherwise, try to convert
	format "  %\n" orig_mtl
	local new_mtl=case cls of (
		StandardMaterial: convertFrom_Standard orig_mtl
		RaytraceMaterial: convertFrom_Raytrace orig_mtl
		Architectural: convertFrom_Architectural orig_mtl
		PhysicalMaterial: if (vraySceneConverterRollout.check_optConvertPhysicalMtl.checked) then (convertFrom_PhysicalMaterial orig_mtl) else orig_mtl

		fR_Advanced: convertFrom_fR_Advanced orig_mtl
		fR_Metal: convertFrom_fR_Metal orig_mtl
		fR_Glass: convertFrom_fR_Glass orig_mtl

		Blend: convertFromBlend orig_mtl
		Shellac: convertFromShellac orig_mtl
		DoubleSided: convertFromDoubleSided orig_mtl

		CoronaMtl: convertFrom_CoronaMtl orig_mtl
		CoronaLayeredMtl: convertFrom_CoronaLayeredMtl orig_mtl
		CoronaLightMtl: convertFrom_CoronaLightMtl orig_mtl
		CoronaRaySwitchMtl: convertFrom_CoronaRaySwitchMtl orig_mtl
		CoronaPortalMtl: VRayMtl name:("_VRB." + orig_mtl.name)
		CoronaVolumeMtl: convertFrom_CoronaVolumeMtl orig_mtl
		CoronaHairMtl: convertFrom_CoronaHairMtl orig_mtl
		CoronaSkinMtl: convertFrom_CoronaSkinMtl orig_mtl
		CoronaPhysicalMtl: convertFrom_CoronaPhysicalMtl orig_mtl "full"


		-- Do not convert Arch&Design materials - V-Ray supports them directly
		-- Arch___Design__mi: orig_mtl

		default: orig_mtl
	)

	-- if converted, add to the list of converted materials
	if new_mtl!=orig_mtl then (
		append orig_mtls orig_mtl
		append new_mtls new_mtl
		--here we create a node in Slate Material Editor
		--for newly created material
		createSMENodeByRef orig_mtl new_mtl
	)

	-- return the new material
	new_mtl
)

--convert CoronaLight texmap to VRay texture
fn coronaLightTexToVRayTex node = (
	if (isValidNode node and (classof node == CoronaLight)) then (
		format "Converting node % texture...\n" node.name
		local tex=createVRayTexture node.texmap
		createSMENodeByRef node.texmap tex
		node.texmap=tex
		format "Done\n"
	)
)

-- convert node materials to VRay materials
fn mtlsToVRay node = (
	if (isValidNode node) then (
		format "Converting node % materials...\n" node.name
		local m=createVRayMtl node.material
		node.material=m
		format "Done\n"
	)
)

-- traverse scene nodes in order to convert specific properties
-- like materials, shadows, ets., to VRay and replace the originals with the converted ones
fn replaceNodeProperties node = (
	if isValidNode node then (
		coronaLightTexToVRayTex node
		mtlsToVRay node
		shadowsToVRay node
	)
	for i=1 to node.children.count do (
		replaceNodeProperties node.children[i]
	)
)

fn deselectSMENodes = (
	if (maxver < 13000) do return undefined

	local numViews = sme.GetNumViews()
	for iView=1 to numViews do (
		local currentView = sme.GetView iView
		local numNodes = currentView.GetNumNodes()
		for iNode=1 to numNodes do (
			local currentNode = currentView.GetNode iNode
			currentNode.selected = false
		)
	)
)

fn selectSMENodeByRef objRef = (
	if (maxver < 13000) do return undefined

	local numViews = sme.GetNumViews()
	for iView=1 to numViews do (
		local currentView = sme.GetView iView
		local nodeByRef = currentView.GetNodeByRef objRef
		if (nodeByRef != undefined) then (
			nodeByRef.selected = true
			print nodeByRef.name
		)
	)
)

fn deleteSMESelectedNodesInEachView = (
	if (maxver < 13000) do return undefined

	local numViews = sme.GetNumViews()
	for iView=1 to numViews do (
		local currentView = sme.GetView iView
		currentView.DeleteSelection()
	)
)

fn showMtlSlotInSME activeSlot= (

	local m = getMeditMaterial activeSlot
	local maxver = (maxVersion())[1]
	if (maxver >= 13000 and MatEditor.mode == #advanced) then (
		local vrmatViewIdx = sme.GetViewByName "VRayMtlView"
		if (vrmatViewIdx == 0) then (
			vrmatViewIdx = sme.CreateView "VRayMtlView"
		)
		local vrmatView = sme.GetView vrmatViewIdx

		if (vrmatView != undefined) then (
			vrmatView.CreateNode m [0,0]
		)
	)
)

fn showMtlSlotInCurrentSMEView activeSlot= (

	local m = getMeditMaterial activeSlot
	local vrmatViewIdx = sme.activeView
	if (vrmatViewIdx == 0) then (
		vrmatViewIdx = 1
	)

	local vrmatView = sme.GetView vrmatViewIdx
	if (vrmatView != undefined) then (
		vrmatView.CreateNode m [0,0]
	)
)

fn mtlExistsInSME mtlName= (
	for i=1 to sme.GetNumViews() do (
		view=sme.GetView(i)
		for j=1 to view.GetNumNodes() do (
			node=view.GetNode(j)
			if (node.name == mtlName) then (
				return true
			)
		)
	)
	return false
)

fn warningToSelectGeometry theOperationName= (
	format "V-Ray Toolbar WARNING!\n"
	format "In order to create % you have to select geometry first!\n" theOperationName
)

fn shadowsNode node = (
	if (isValidNode node) then (
		scls=superclassof node
		if (scls==light) then (
			try (
				olds=node.shadowGenerator
				cls=classof olds
				if (cls!=shadowMap and cls!=VRayShadow) then (
					format "  %\n" node
					news=VRayShadow()
					node.shadowGenerator=news
				)
			)
			catch ()
		)
	)

	for i=1 to node.children.count do (
		shadowsNode node.children[i]
	)
)

-- convert all node shadow types except shadow maps to VRay shadows
fn shadowsToVRay node = (
	format "Converting node % shadows...\n" node.name
	shadowsNode node
	format "Done\n"
)

fn convertFrom_CoronaIESLight cLt = (

	local newLight=CreateInstance VRayIES name:(cLt.name+"_VRayIESLight")

	newLight.enabled = cLt.on
	newLight.targeted = cLt.targeted

	case of (
		(cLt.excludeList != undefined and cLt.excludeIncludeMod == true): (
			newLight.includeList = cLt.excludeList
		)
		(cLt.excludeList != undefined and cLt.excludeIncludeMod == false): (
			newLight.excludeList = cLt.excludeList
		)
		default: ()
	)

	-- Intensitiy, Color, Texmap
	newLight.power = cLt.intensity

	newLight.color_mode = cLt.colorMode -- 0: direct color, 1: kelvin temp
	newLight.color = cLt.color
	if cLt.colorMode == 1 do newLight.color_temperature = cLt.blackbodyTemp -- kelvin

	-- shape   -- 0: sphere, 1: rectangle, 2: disk, 3: cylinder
	newLight.override_shape = on
	case cLt.shape of (
		0:( newLight.shape = 3 -- sphere
			newLight.diameter = cLt.width * 2
		)
		1:( newLight.shape = 1 -- rectangle
			newLight.width = cLt.width
			newLight.length = cLt.height
		)
		2:( newLight.shape = 2 -- circle
			newLight.diameter = cLt.width * 2
		)
		3:( newLight.shape = 4  -- vertical cylinder
			newLight.diameter = cLt.width * 2.0
			newLight.height = cLt.height
		)
		default:(
		)
	)

	-- visibility
	newLight.cast_shadows = cLt.occludeOtherLights

	-- IES
	if cLt.iesFile != undefined do(
		newLight.ies_file = cLt.iesFile
	)

	newLight
)

fn replaceCoronaLightNodeVRayLight cLt = (
	local theVRL = undefined
	if cLt.iesOn == true and cLt.iesFile != undefined and cLt.iesFile != "" then (
		theVRL = convertFrom_CoronaIESLight cLt
	) else (
		theVRL=CreateInstance VRayLight name:(cLt.name+"_VRayLight") on:cLt.on castShadows:cLt.occludeOtherLights invisible:(not cLt.visibleDirectly) \
		affect_reflections:cLt.visibleRefl color_mode:cLt.colorMode  color:cLt.color targeted:cLt.targeted

		if cLt.colorMode == 1 do theVRL.color_temperature = cLt.blackbodyTemp
		if cLt.colorMode == 2 do theVRL.texmap_on = true
		if cLt.texmap != undefined do theVRL.texmap = cLt.texmap

		if cLt.targeted == true do theVRL.target_distance = cLt.targetDistance

		theVRL.lightDistribution = cLt.directionality

		--Include/Exclude
		if (cLt.excludeList != undefined and cLt.excludeList.count !=0) do (
			theVRL.inclExclType = 1
			if cLt.excludeIncludeMod then theVRL.includeList = cLt.excludeList else theVRL.excludeList = cLt.excludeList
		)

		--Color/ Intensity
		theVRL.normalizeColor = case of
		(
			(cLt.intensityUnits == 0):0
			(cLt.intensityUnits == 1):1
			default:0
		)

		theVRL.multiplier = cLt.intensity

		--shape
		case cLt.shape  of
		(
			1: ( --Plane
				theVRL.type = 0
				theVRL.size0 = cLt.width/2.0
				theVRL.size1 = cLt.height/2.0
			)
			0: ( --Sphere
				theVRL.type = 2
				theVRL.size0 = cLt.width
			)
			2: ( --Disc
				theVRL.type = 4
				theVRL.size0 = cLt.width/2.0
			)
			3: ( --Cylinder
				theVRL.type = 2
				theVRL.size0 = cLt.width
			)
		)
	)
	instCount = InstanceMgr.GetInstances cLt &arrInst
	for i=1 to instCount do
		arrInst[i].name = (arrInst[i].name+"_VRayLight")
	replaceInstances cLt theVRL
	theVRL
)

--here input param : 'ver' have to be presented as <number>.<number>.{<number>}
fn checkForPreviousCoronaVersion ver = (
	res = false
	if CoronaRenderer != undefined do (
		local currVer = CoronaRenderer.getCoronaVersion()
		local parsedCurrVer = filterstring currVer " ,."
		local intCurrVer = ((parsedCurrVer[1]+parsedCurrVer[2]) as integer)
		local parsedVer = filterstring ver " ,."
		local intVer = ((parsedVer[1]+parsedVer[2]) as integer)
		if intCurrVer != undefined and intVer != undefined then
			res = (intCurrVer < intVer)
	)
	return res
)

fn replaceCoronaSunLightNodeVRayLight coronaSLNode = (
	local sunObj = undefined
	local targetObj = undefined
	local previousVersion = checkForPreviousCoronaVersion("1.2.1")

	if previousVersion then (
		sunObj = VRaySun name:(coronaSLNode.name+"_VRaySun") enabled:coronaSLNode.on intensity_multiplier:coronaSLNode.intensity size_multiplier:coronaSLNode.sizeMultiplier invisible:(not coronaSLNode.visibleDirectly)
		targetObj = dummy name:(coronaSLNode.name+"_VRaySun.Target") pos:coronaSLNode.pos  --then target
		targetObj.boxsize = [2,2,2]
		targetObj.lookat = sunObj --this makes the target for the sunn out of dummy object
		sunObj.pos = coronaSLNode.pos + coronaSLNode.displaySize*[sin coronaSLNode.height, 0.0, cos coronaSLNode.height] -- xy
		sunObj.pos = [coronaSLNode.pos.x , coronaSLNode.pos.y, sunObj.pos.z]  + [cos coronaSLNode.sunRotation , sin coronaSLNode.sunRotation, 0.0]*sqrt(coronaSLNode.displaySize^2 - sunObj.pos.z^2) --z

		--animated sun
		if coronaSLNode.sunRotation.isAnimated == true or coronaSLNode.height.isAnimated == true do
		(
			animate on
			for t in animationRange.start to animationRange.end by 1 do
			(
				at time t
				(
					sunObj.pos = coronaSLNode.pos + coronaSLNode.displaySize*[sin coronaSLNode.height, 0.0, cos coronaSLNode.height]
					sunObj.pos = [coronaSLNode.pos.x , coronaSLNode.pos.y, sunObj.pos.z]  + [cos coronaSLNode.sunRotation , sin coronaSLNode.sunRotation, 0.0]*sqrt(coronaSLNode.displaySize^2 - sunObj.pos.z^2)
				)
			)
		)
	) else (
		sunObj = CreateInstance VRaySun name:(coronaSLNode.name+"_VRaySun") enabled:coronaSLNode.on intensity_multiplier:coronaSLNode.intensity size_multiplier:coronaSLNode.sizeMultiplier invisible:(not coronaSLNode.visibleDirectly)
	)

	if (coronaSLNode.colorMode == 0) do (
		sunObj.color_mode = 1
		sunObj.filter_Color = coronaSLNode.colorDirect
	)

	--excludeList
	if coronaSLNode.excludeList.count != 0 do
	(
		sunObj.inclExclType = 1
		if coronaSLNode.excludeListIncludeMod == false then sunObj.excludeList = coronaSLNode.excludeList else sunObj.includeList = coronaSLNode.excludeList
	)

	if previousVersion then (
		theLayer = layermanager.getLayerFromName coronaSLNode.layer.name
		theLayer.addNode sunObj
		theLayer.addNode targetObj

		delete coronaSLNode
	) else (
		instCount = InstanceMgr.GetInstances coronaSLNode &arrInst
		for i=1 to instCount do (
			arrInst[i].name = (arrInst[i].name+"_VRaySun")
		)
		replaceInstances coronaSLNode sunObj
	)

	return undefined
)

fn normalizeColor col = (
	norm=if (col.r>col.g) then (if (col.r>col.b) then col.r else col.b) else (if (col.g>col.b) then col.g else col.b)
	result=color ((col.r*255.0)/norm) ((col.g*255.0)/norm) ((col.b*255.0)/norm)
	result
)

fn replaceLightNodeVRIESLight node = (
	local newLight=CreateInstance VRayIES name:(node.name+"_VRayIESLight")

	if (newLight!=undefined) do (
		newLight.targeted=(node.target!=undefined)
		newLight.enabled=node.on
		newLight.color_mode=0
		newLight.color=normalizeColor node.color
		newLight.rotation_X=node.xRotation
		newLight.rotation_Y=node.yRotation
		newLight.rotation_Z=node.zRotation
		newLight.use_light_shape=1
		if (node.webFile!=undefined) then (
			newLight.ies_file=node.webFile
			local powerCoeff=node.intensity/node.originalIntensity
			newLight.power=newLight.power*powerCoeff
		) else (
			newLight.power=node.intensity*4*pi
		)
		if (node.useMultiplier) do (newLight.power=(newLight.power*node.multiplier)/100.0)
		if (hasProperty newLight "override_shape") then (
			newLight.override_shape=true
			case of (
				(node.type==#Target_Point or node.type==#Free_Point): (
					newLight.shape=0
				)

				(node.type==#Target_Line or node.type==#Free_Line or
				node.type==#Target_Linear or node.type==#Free_Linear): (
					newLight.shape=1
					newLight.length=node.light_length
				)

				(node.type==#Target_Rectangle or node.type==#Free_Rectangle or
				node.type==#Target_Area or node.type==#Free_Area): (
					newLight.shape=1
					newLight.width=node.light_width
					newLight.length=node.light_length
				)

				(node.type==#Target_Disc or node.type==#Free_Disc): (
					newLight.shape=2
					newLight.diameter=node.light_radius*2
				)

				(node.type==#Target_Sphere or node.type==#Free_Sphere): (
					newLight.shape=3
					newLight.diameter=node.light_radius*2
				)

				(node.type==#Target_Cylinder or node.type==#Free_Cylinder): (
					newLight.shape=5
					newLight.length=node.light_length
					newLight.diameter=node.light_radius*2
				)
			)
		)
		if (node.includeList!=undefined) do (newLight.includeList=node.includeList)
		if (node.excludeList!=undefined) do (newLight.excludeList=node.excludeList)
	)

	instCount = InstanceMgr.GetInstances node &arrInst
	for i=1 to instCount do (
		arrInst[i].name = (arrInst[i].name+"_VRayIESLight")
	)
	replaceInstances node newLight
	newLight
)

fn replaceLightNodeVRayLight node = (
	local newLight=CreateInstance VRayLight name:(node.name+"_VRayLight")

	if (newLight!=undefined) do (
		newLight.targeted=(node.target!=undefined)
		if newLight.targeted then newLight.target_distance = node.targetDistance
		newLight.on=node.on
		newLight.color_mode=0
		newLight.color=normalizeColor node.color
		newLight.normalizeColor = 1
		newLight.multiplier=node.intensity*4*pi
		newLight.invisible= not node.baseObject.Area_Light_Sampling_Custom_Attribute.mr_EnableLightShapeRendering
		newLight.texmap_on=node.projector
		if (node.projector) do newLight.texmap=node.projectorMap
		if (node.useMultiplier) do (newLight.multiplier=(newLight.multiplier*node.multiplier)/100.0)
		case of (
			(node.type==#Target_Rectangle or node.type==#Free_Rectangle or
			node.type==#Target_Area or node.type==#Free_Area): (
				newLight.type=0
				newLight.size0=node.light_width / 2.0
				newLight.size1=node.light_length / 2.0
				newLight.DoubleSided = true
			)

			(node.type==#Target_Disc or node.type==#Free_Disc): (
				newLight.type=4
				newLight.size0=node.light_radius
				newLight.DoubleSided = true
			)

			(node.type==#Target_Sphere or node.type==#Free_Sphere): (
				newLight.type=2
				newLight.size0=node.light_radius
			)
		)

		if (node.includeList!=undefined) do (newLight.includeList=node.includeList)
		if (node.excludeList!=undefined) do (newLight.excludeList=node.excludeList)
	)

	instCount = InstanceMgr.GetInstances node &arrInst
	for i=1 to instCount do
		arrInst[i].name = (arrInst[i].name+"_VRayLight")
	replaceInstances node newLight
	newLight
)

fn replaceLight_mr_Sun lightsys = (
	if (classof lightsys.sun==mr_Sun) do (
		local mrSun_on=lightsys.sun.on
		local mrSun_skymult=lightsys.sun.skymult

		lightsys.sun=createInstance VRaySun
		lightsys.sun.enabled=mrSun_on
		lightsys.sun.intensity_multiplier=mrSun_skymult

		lightsys.sky=undefined
	)
)

fn replaceLightNode node = (
	local lightClassStandard=#(Free_Light, Target_Light,
									Free_Point, Target_Point,
									Free_Linear, Target_Linear,
									Free_Area, Target_Area,
									Free_Disc, Target_Disc,
									Free_Sphere, Target_Sphere,
									Free_Cylinder, Target_Cylinder)

	local lightClassCorona=#(CoronaLight, CoronaSun)
	local newLight
	if (isValidNode node) do (
		if ((findItem lightClassStandard (classof node))!=0) do (
			case (node.distribution) of (
				0: newLight=replaceLightNodeVRayLight node	-- Uniform Spherical
				1: newLight=undefined						-- Spotlight
				2: newLight=replaceLightNodeVRayLight node	-- Uniform Diffuse
				3: newLight=replaceLightNodeVRIESLight node	-- Photometric Web
			)
		)

		local foundCL = 0
		if ((foundCL = findItem lightClassCorona (classof node))!=0) do (
			case (foundCL) of (
				1: newLight=replaceCoronaLightNodeVRayLight node	-- Uniform Spherical
				2: newLight=replaceCoronaSunLightNodeVRayLight node
			)
		)
	)

	if (newLight!=undefined) do (
		print (node.name)
	)

	newLight!=undefined
)

fn lightsToVRay selectedOnly = (
	format "Converting scene Lights...\n"
	local oldLights=#()

	-- First traverse scene for daylight systems otherwise the sun/sky lights in them will appear as standalone
	-- lights to the normal lights replace traversal.
	if (vraySceneConverterRollout.check_optLights.checked) do (
		for i=1 to $helpers.count do (
			if (classof $helpers[i]==DaylightAssemblyHead) do (
				replaceLight_mr_Sun $helpers[i]
			)
		)

		if ((environmentMap!=undefined) and (classof environmentMap==mr_Physical_Sky)) do (
			environmentMap=VRaySky()
		)
	)

	if selectedOnly do  format "Converting scene Lights for selected lights...\n"
	for i=1 to $lights.count do (
		if selectedOnly then (
			if $lights[i].isSelected do
				if (replaceLightNode $lights[i]) do ( append oldLights $lights[i] )
		) else (
			if (replaceLightNode $lights[i]) do ( append oldLights $lights[i] )
		)
	)
	-- old lights need to stay until the conversion is done, because deleteing them
	-- on the run messes nodes' order during traversal
	format "Done\n"
)

fn replaceLightMeter node=(
	local vrLightMeter = undefined
	if (classof node==LightMeter) do (
		vrLightMeter = CreateInstance VRayLightMeter
		-- try to convert
		format "  %\n" node
		vrLightMeter.active = node.active
		vrLightMeter.width = node.width
		vrLightMeter.length = node.length
		vrLightMeter.wsegs = node.width_segs
		vrLightMeter.lsegs = node.length_segs
		vrLightMeter.orient = node.showOrientation
		vrLightMeter.dispvalue = node.valuesToDisplay
		vrLightMeter.text = node.showViewportText
		vrLightMeter.colors = node.showPsuedoColor

		vrLightMeter.log = (PseudoColorManager.scaleType == #logarithmic)
		vrLightMeter.min_lux = PseudoColorManager.rangeStart
		vrLightMeter.max_lux = PseudoColorManager.rangeEnd

		instCount = InstanceMgr.GetInstances node &arrInst
		for i=1 to instCount do
			arrInst[i].name = (arrInst[i].name+"_VRayLightMeter")

		replaceInstances node vrLightMeter
	)

	if (vrLightMeter != undefined) do (
		print (node.name)
	)

	vrLightMeter != undefined
)

fn lightmetersToVRay selectedOnly = (
	format "Converting scene LightMeters...\n"
	local oldLightMeters=#()
	if selectedOnly do  format "Converting scene LightMeters for selected ones...\n"
	for i=1 to $helpers.count do (
		if selectedOnly then (
			if $helpers[i].isSelected do
				if (replaceLightMeter $helpers[i]) do ( append oldLightMeters $helpers[i] )
		) else (
			if (replaceLightMeter $helpers[i]) do ( append oldLightMeters $helpers[i] )
		)
	)

	format "Done\n"
)

fn replaceCoronaCameraNode node = (
	local newCamera=CreateInstance VRayPhysicalCamera specify_fov: on pos: node.pos
	local newCameraName = "_VRayPhysicalCamera"

	if (isValidNode node and newCamera!=undefined) do (
		--ViewportDisplay -> Basic&Display
		newCamera.targeted = node.targeted
		newCamera.target_distance = node.targetDistance
		case node.showCone of (
			0: newCamera.show_camera_cone = 1 --always
			1: newCamera.show_camera_cone = 0 --selected
			2: newCamera.show_camera_cone = 2 --never
		)
		newCamera.horizon_on = node.showHorizonLine

		--Sensor&Lens
		newCamera.specify_fov = (node.fovSource == 0)
		newCamera.fov = node.fov
		newCamera.focal_length = node.focalLength
		newCamera.zoom_factor = node.zoomFactor
		newCamera.ISO = node.ISO
		newCamera.f_number = node.fStop
		case node.shutterParam of (
			0:(
				newCamera.type = 0
				newCamera.shutter_speed = node.shutterSpeed
			)
			1:(
				newCamera.type = 1
				newCamera.shutter_angle = node.shutterAngle --in deg
				if node.enableCameraMb == on do
					newCamera.shutter_offset = node.shutterOffset
			)
			2:(
				newCamera.type = 2
				newCamera.latency = node.mblurDuration
			)
		)
		--Distortion
		if node.distortionType == 1 do (
			newCamera.distortion_type = 1
			newCamera.distortion = node.distortionAmount
		)
		if node.distortionType == 2 do (
			newCamer.distortion_type = 3
			newCamera.distortion_map = node.distortionMap
		)
		--DOF&MotionBlur
		newCamera.use_dof = node.enableDof
		newCamera.use_moblur = node.enableCameraMb

		--Bokeh effects
		if node.overrideBokeh == on then (
			if node.bokehType == 1 do (
				newCamera.use_blades = on
				newCamera.blades_number = node.bokehBladeCount
				newCamera.blades_rotation = node.bokehRotation
			)
			if node.bokehType == 2 do (
				newCamera.bitmap_aperture_texmap = node.bokehMap
				newCamera.bitmap_aperture_affectExposure = node.bokehMapAffectsExposure
			)
		)
		--Bokeh advanced effects
		newCamera.center_bias = node.bokehCenterBias
		newCamera.anisotropy = node.bokehAnisotropy
		newCamera.optical_vignetting = node.bokehVignetting

		--Tilt&Shift
		newCamera.lens_tilt_auto = node.autoVerticalTilt
		newCamera.lens_tilt = node.verticalTilt
		newCamera.lens_horTilt = node.horizontalTilt
		newCamera.vertical_shift = node.verticalShift
		newCamera.horizontal_shift = node.horizontalShift

		--Environment&Clipping
		newCamera.clip_on = node.enableClipping
		newCamera.clip_near = node.clippingNear
		newCamera.clip_far = node.clippingFar
		newCamera.environment_near = node.enviroNear
		newCamera.environment_far = node.enviroFar

		--Tone mapping
		if node.overrideToneMapping == on and node.enableToneMapping then (
			if node.vignette > 0.0 do (
				newCamera.vignetting = on
				newCamera.vignetting_amount = node.vignette
			)
			newCamera.whiteBalance_preset = 0
			newCamera.whiteBalance = node.colorTint
			--node.colorTint
			--node.whiteBalance (temperature)
		)
	)

	if (isValidNode node) do (
		instCount = InstanceMgr.GetInstances node &arrInst
		for i=1 to instCount do
			arrInst[i].name = (arrInst[i].name+newCameraName)
		replaceInstances node newCamera
	)

	newCamera!=undefined
)

fn replaceCameraNode node = (
	local cameraClassStandard=#(Freecamera, Targetcamera)

	local newCamera
	local newCameraName
	if (isValidNode node) do (
		local camIdx = findItem cameraClassStandard (classof node)
		if (camIdx!=0) do (
			--Implementation

			if (vraySceneConverterRollout.ddListCameras.selection == 3) then (
				newCamera=CreateInstance Physical specify_fov: on
				newCameraName = "_PhysicalCamera"
			)

			if (vraySceneConverterRollout.ddListCameras.selection == 2) then (
				newCamera=CreateInstance VRayPhysicalCamera specify_fov: on
				newCameraName = "_VRayPhysicalCamera"
			)

			if (newCamera!=undefined) do (
				local newCameraClass = classof newCamera
				if (camIdx == 1) then (
					newCamera.targeted = off
					newCamera.target_distance = node.baseObject.targetDistance
				)
				else (
					newCamera.targeted = off
					newCamera.target_distance = node.targetDistance
					newCamera.targeted = on
				)

				if (node.fov.isAnimated) then(
					classOfNodeController = classof node.fov.controller
					--newCamera.fov.controller=bezier_float()
					newCamera.fov.controller = createInstance classOfNodeController
					nkeys = node.fov.keys
					for k in nkeys do appendKey newCamera.fov.keys k
					for i=1 to nkeys.count do (
						newCamera.fov.keys[i].value=node.fov.keys[i].value
					)
				) else (
					newCamera.fov = node.fov -- By some reason Max Physical Camera does not accept fov value
				)

				newCamera.specify_fov = off

				if (node.showRanges == on) then (
					newCamera.environment_near = node.nearrange
					newCamera.environment_far = node.farrange
				)

				newCamera.clip_on = node.clipManually
				newCamera.clip_near = node.nearclip
				newCamera.clip_far = node.farclip

				if (node.mpassEnabled == on) then (
					local mpEffectClass = classof node.mpassEffect
					case mpEffectClass of (
						Depth_of_FieldMPassCamEffect: (
							newCamera.use_dof = on
							if (newCameraClass == Physical) then (
								newCamera.motion_blur_enabled = off
								newCamera.focus_distance = node.mpassEffect.focalDepth
								if (node.mpassEffect.useTargetDistance == on) then newCamera.specify_focus = 0
								else newCamera.specify_focus = 1
							)
							else newCamera.use_moblur = off
						)
						Motion_BlurMPassCamEffect: (
							newCamera.use_dof = off
							if (newCameraClass == Physical) do newCamera.motion_blur_enabled = on
							if (newCameraClass == VRayPhysicalCamera) do newCamera.use_moblur = on
						)
						Depth_of_Field__mental_ray: (
							newCamera.use_dof = on
						)
					)
				)

				instCount = InstanceMgr.GetInstances node &arrInst
				for i=1 to instCount do
					arrInst[i].name = (arrInst[i].name+newCameraName)
				replaceInstances node newCamera
			)
		)
	)

	if (newCamera!=undefined) do (
		print (node.name)
	)

	newCamera!=undefined
)

fn camerasToVRay selectedOnly = (
	if (vraySceneConverterRollout.ddListCameras.selection > 1) then (
		format "Converting scene Cameras...\n"
		local oldCameras=#()

		if selectedOnly do format "Converting scene Cameras for selected cameras only...\n"
		for i=1 to $cameras.count do (
			if selectedOnly then (
				if $cameras[i].isSelected do (
					if (classof $cameras[i] == CoronaCam) then (
						if (replaceCoronaCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
					) else (
						if (replaceCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
					)
				)
			) else (
				if (classof $cameras[i] == CoronaCam) then (
					if (replaceCoronaCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
				) else (
					if (replaceCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
				)
			)
		)
		-- old cameras need to stay until the conversion is done, because deleteing them
		-- on the run messes nodes' order during traversal
		format "Done\n"
	) else (
		format "Converting scene Corona Cameras...\n"
		local oldCameras=#()

		if selectedOnly do format "Converting scene Corona Cameras for selected cameras only...\n"
		for i=1 to $cameras.count do (
			if selectedOnly then (
				if $cameras[i].isSelected do (
					if (classof $cameras[i] == CoronaCam) do (
						if (replaceCoronaCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
					)
				)
			) else (
				if (classof $cameras[i] == CoronaCam) do (
					if (replaceCoronaCameraNode $cameras[i]) do ( append oldCameras $cameras[i] )
				)
			)
		)
		-- old cameras need to stay until the conversion is done, because deleteing them
		-- on the run messes nodes' order during traversal
		format "Done\n"
	)
)

--Convert Corona Proxy to VRay Proxy
fn getOrigCoronaProxy  selectedOnly =  ( --get list of original proxies
	arrayOrigCoronaProxy = #()
	arrayOrigCoronaProxy_pathes = #()
	 for i in objects where (classOf i == CProxy)  and (not selectedOnly or selectedOnly and i.isSelected) do
	 (
		 if (findItem arrayOrigCoronaProxy_pathes  i.filename) == 0 and doesFileExist i.filename != false do
		 (
			append arrayOrigCoronaProxy i
			append arrayOrigCoronaProxy_pathes i.filename
		)
	)
	arrayOrigCoronaProxy
)

fn getData_InstProxy_byOrig ocp = ( --get list of dependent proxies
	arrayCoronaProxy = #()
	for i in objects where classOf i == CProxy do
	(
		if i.filename != undefined and i.filename == ocp.filename do append arrayCoronaProxy #(i, i.name, getFilenameFile  i.filename, getFilenamePath i.filename, i.transform, i.previzType)
	)
	arrayCoronaProxy
)

fn coronaProxiesToVRay thePath selectedOnly = (
	OrigCorPr = getOrigCoronaProxy selectedOnly --list of corona proxies
	if OrigCorPr.count != 0 do (
		numCP = OrigCorPr.count
		for i = 1 to numCP do (
			theData_InstCorPr = getData_InstProxy_byOrig OrigCorPr[i] -- list of proxies related to each corona poxy

			tempObj = instance OrigCorPr[i] wirecolor:red
			tempObj.transform = (matrix3 [1,0,0] [0,1,0] [0,0,1] [0,0,0])
			tempObj.previzType = 3
			converttomesh tempObj
			objNF = (tempObj.numfaces/10.0) as integer -- preview 1/10 ot numfaces


			tempObj.name = theData_InstCorPr[1][3]
			select tempObj
			if thePath != undefined and thePath != "Select path please..." then (
				tempVRayPr = vrayMeshExport tempObj autoCreateProxies:true maxPreviewFaces:objNF  meshfile:(thePath + "\\" + theData_InstCorPr[1][3])
			) else (
				tempVRayPr = vrayMeshExport tempObj autoCreateProxies:true maxPreviewFaces:objNF  meshfile:(theData_InstCorPr[1][4] + theData_InstCorPr[1][3])
			)
			tempVRayPr[1].display = 0
			tempVRayPr[1].visibility_lists_type = 0
			tempVRayPr[1].visibility_list_names[1] = false
			for i in (getData_InstProxy_byOrig OrigCorPr[i]) do i[1].name = uniqueName tempObj.name

			--replace each corona proxy with vray proxy -> tempVRayPr
			instanceReplace OrigCorPr[i] tempVRayPr[1]
			delete tempVRayPr
		)
	)
)

fn lightingAnalysisOverlayToVRayLightingAnalysis = (
	theManager = maxOps.GetRenderElementMgr #Production
	listOfLightingEffectsIdxs = #()
	for i=1 to numEffects do (
		iEffect = (getEffect i)
		if classof iEffect == Lighting_Analysis_Overlay then (
			local newVRLightingAnalysis = VRayLightingAnalysis name: iEffect.name
			newVRLightingAnalysis.vrayVFB = (IsActive iEffect)
			if iEffect.quantity == 0 then newVRLightingAnalysis.quantity = 1
			else newVRLightingAnalysis.quantity = 0
			newVRLightingAnalysis.scale = iEffect.scaleType
			newVRLightingAnalysis.min_value = iEffect.rangeStart
			newVRLightingAnalysis.max_value = iEffect.rangeEnd
			if iEffect.shownumbers == on then (
				newVRLightingAnalysis.display = 1
				newVRLightingAnalysis.grid_horizontal_spacing = iEffect.horizontalspacing
				newVRLightingAnalysis.grid_vertical_spacing = iEffect.verticalspacing
				newVRLightingAnalysis.fade_background_image = iEffect.fadeBackground
			)
			theManager.AddRenderElement  newVRLightingAnalysis
			append listOfLightingEffectsIdxs i
		)
	)
	print listOfLightingEffectsIdxs
	for idx = listOfLightingEffectsIdxs.count to 1 by -1 do (
		deleteEffect listOfLightingEffectsIdxs[idx]
	)
)

-- The main function called when 'Convert' button from 'V-Ray scene converter' is pressed
-- It contains all functions that convert scene objects by classes
fn ConvertToVRay selectedOnly = (
	orig_mtls=#()
	new_mtls=#()
	orig_texmaps=#()
	new_texmaps=#()

	-- Disable scene redraw during the conversion in order to prevent 3ds Max from updating the viewports after every change
	with redraw off (
		if selectedOnly then (
			local numNodes = selection.count
			for iNode=1 to numNodes do (
				print selection[iNode]
				replaceNodeProperties selection[iNode]
			)
		) else (
			replaceNodeProperties rootNode

			format "Converting Material Editor materials...\n"
			for i=1 to 24 do (
				local m=createVRayMtl meditmaterials[i]
				meditmaterials[i]=m
			)
			format "Done\n"
			format "Converting Environment Map...\n"
			local envtex=createVRayTexture environmentMap
			if (envtex!=undefined) do (
				createSMENodeByRef environmentMap envtex
				environmentMap=envtex
			)
			format "Done\n"
		)

		lightmetersToVRay selectedOnly
		lightsToVRay selectedOnly
		camerasToVRay selectedOnly
		coronaProxiesToVRay undefined selectedOnly
		lightingAnalysisOverlayToVRayLightingAnalysis()
	)

	orig_mtls=#()
	new_mtls=#()
	orig_texmaps=#()
	new_texmaps=#()
)
convertToVRay=ConvertToVRay

-- Bitmap2VRayBitmap converter
convertB2HDRI_ConvertEXR=false
convertB2HDRI_ConverterErrors=0
convertB2HDRI_ErrorsInTXExisting=0 --named only for Tx because of upcoming exr conversion elimination

listOfSuppFormats = #(".png", ".bmp", ".tga", ".hdr", ".sgi", ".rgb", ".rgba", ".jpg", ".jpeg", ".jpe", ".exr", ".pic", ".tif", ".tiff", ".psd")
mapfiles=#() --list of bitmap image file paths

--The next function is passed as 'enumeratefiles' argument and is called for each file found.
--The mapfile argument is the string file name supplied by the enumerator.
fn addmap mapfile = (
	local index=finditem mapfiles mapfile
	local idFormatType = finditem listOfSuppFormats (tolower(getFilenameType mapfile))
	if (index==0 and idFormatType > 0) do append mapfiles mapfile
)

fn convertImgToTiledEXR convertHalf convertCompression convertTilesize convertLinear = (
	--print "********** START CONVERSION  Image --> Tiled EXR ****************"
	start = timeStamp()
	if (convertPath==undefined) do (
		local ver=getMaxReleaseAsString()
		convertPath = getVRayInstallPath ver
	)
	mapfiles=#()
	--The following method is used to collect a list of the bitmap files used in a scene.
	enumeratefiles addmap
	local iImg = 0
	local mapfilesCount = mapfiles.count
	--The real conversion done by 'img2tiledexr.exe' according to specified options for each mapfile from list - mapfiles
	for mapfile in mapfiles do (
		windows.processPostedMessages()
		fullImgPath = mapPaths.getFullFilePath mapfile
		if ((classof fullImgPath)==String) then (
			if ((stricmp (getFilenameType fullImgPath) ".exr")!=0) do (
				outpath=(getFilenamePath fullImgPath)+(getFilenameFile fullImgPath)+".exr"
				if (not (doesFileExist outpath)) do (
					if ((classof convertPath)==String) do (
						local cmdConverter=("\""+convertPath+"\" \""+fullImgPath+"\" \""+outpath+"\"")
						if (convertHalf) then (append cmdConverter " -half")
						else (append cmdConverter " -32bit")
						append cmdConverter (" -compression "+convertCompression)
						append cmdConverter (" -tileSize "+(convertTilesize as String))
						append cmdConverter (" -linear "+convertLinear)

						vrayShellLaunch cmdConverter waitExec:true hideConsole:true
					)
				)

				if (not (doesFileExist outpath)) do (
						format "Failed to convert % to tiled EXR,\n please check if you have write permissions for %\n" fullImgPath outpath
					)
				)
			)
		iImg = iImg + 1
		convertB2HDRI_Rollout.prog_convert.value = 100.*iImg/mapfilesCount
	)
	convertB2HDRI_Rollout.prog_convert.value = 0
	end = timeStamp()
	format "Converting took % seconds\n" ((end - start) / 1000.0)
	--print "**********   END CONVERSION  Image --> Tiled EXR ****************"
)

fn convertImgToTX = (
	--print "********** START CONVERSION  Image --> Tiled, MIP-mapped textures ****************"
	start = timeStamp()
	if (convertPath==undefined) do (
		local ver=getMaxReleaseAsString()
		convertPath = getVRayInstallPath ver
	)
	mapfiles=#()
	--The following method is used to collect a list of the bitmap files used in a scene.
	enumeratefiles addmap
	local iImg = 0
	local mapfilesCount = mapfiles.count
	--The real conversion done by 'maketx.exe' for each mapfile from list - mapfiles
	for mapfile in mapfiles do (
		windows.processPostedMessages()
		fullImgPath = mapPaths.getFullFilePath mapfile
		if ((classof fullImgPath)==String) then (
			if ((stricmp (getFilenameType fullImgPath) ".tx")!=0) do (
				outpath=(getFilenamePath fullImgPath)+(getFilenameFile fullImgPath)+".tx"
				if (not (doesFileExist outpath)) do (
					if ((classof convertPath)==String) do (
						local cmdConverter=("\""+convertPath+"\" \""+fullImgPath+"\" -o \""+outpath+"\" --tile 64 64")
						vrayShellLaunch cmdConverter waitExec:true hideConsole:true
					)
				)

				if (not (doesFileExist outpath)) do (
					format "Failed to convert % to TX,\n please check if you have write permissions for %\n" fullImgPath outpath
				)
			)
		)
		iImg = iImg + 1
		convertB2HDRI_Rollout.prog_convert.value = 100.*iImg/mapfilesCount
	)
	convertB2HDRI_Rollout.prog_convert.value = 0
	end = timeStamp()
	format "Converting took % seconds\n" ((end - start) / 1000.0)
	--print "**********   END CONVERSION  Image --> Tiled, MIP-mapped textures ****************"
)



rollout ConvertB2HDRI_TEXRConverterRollout "Img2tiledexr tool conversion options" width: 460 height: 200 (
	label label_message "If the img2tiledexr tool was not found it should be set manually." width:400 height:13 align:#center offset:[0, 10]

	edittext edit_path width:394 across:2 align:#left offset:[13, 0]
	button btn_path "..." width:20 height:18 align:#right offset:[0, 0]

	checkbox check_half "Half - store data as 16-bit floating point numbers." checked:true width:400 align:#center offset:[0, 10]

	label label_compression "Compression method:" width:105 height:13 across:2 align:#left offset:[18, 2]
	dropdownlist drop_compression items:#("None", "RLE", "Zips", "Zip", "PIZ", "PXR24") selection:4 width:100 align:#center offset:[-150, 0]

	label label_tilesize "Tile size:" width:40 height:13 across:2 align:#left offset:[18, 2]
	dropdownlist drop_tilesize items:#("32x32", "64x64", "128x128") selection:2 width:100 align:#center offset:[-150, 0]

	label label_linearmode "Linear mode:" width:60 height:13 across:2 align:#left offset:[18, 2]
	dropdownlist drop_linearmode items:#("Off", "On", "Auto") selection:3 width:100 align:#center offset:[-150, 0]

	button btn_set "OK" width:60 align:#right across:2 offset:[150, 0]
	button btn_cancel "Cancel" width:60 align:#right

	on ConvertB2HDRI_TEXRConverterRollout open do (
		if (convertB2HDRI_Rollout.check_convertEXR.checked) do (
			local tmpPath=convertB2HDRI_Rollout.convertPath
			if (tmpPath!=undefined) do (
				if (doesFileExist tmpPath) do (
					edit_path.text=tmpPath
					edit_path.enabled=false
				)
			)
		)
	)

	on btn_path pressed do (
		local toolPath=getOpenFileName filename:edit_path.text \
								types:"Executable File (img2tiledexr.exe)|img2tiledexr.exe"
		if (toolPath!=undefined) do (
			edit_path.text=toolPath
		)
	)

	on btn_set pressed do (
		convertB2HDRI_Rollout.convertPath=edit_path.text
		convertB2HDRI_Rollout.convertHalf=check_half.checked
		convertB2HDRI_Rollout.convertCompression=case drop_compression.selection of (
			1:	"none"
			2:	"rle"
			3:	"zips"
			4:	"zip"
			5:	"piz"
			6:	"pxr24"
		)
		convertB2HDRI_Rollout.convertTilesize=case drop_tilesize.selection of (
			1:	32
			2:	64
			3:	128
		)
		convertB2HDRI_Rollout.convertLinear=case drop_linearmode.selection of (
			1:	"off"
			2:	"on"
			3:	"auto"
		)

		destroyDialog ConvertB2HDRI_TEXRConverterRollout
	)

	on btn_cancel pressed do (
		convertB2HDRI_Rollout.cancelled=true
		destroyDialog ConvertB2HDRI_TEXRConverterRollout
	)
)

rollout ConvertB2HDRI_MakeTXConverterRollout "MakeTX tool conversion options" width: 460 height: 80 (
	label label_message "If the maketx tool was not found it should be set manually." width:400 height:13 align:#center offset:[0, 10]

	edittext edit_path width:394 across:2 align:#left offset:[13, 0]
	button btn_path "..." width:20 height:18 align:#right offset:[0, 0]

	button btn_set "OK" width:60 align:#right across:2 offset:[150, 0]
	button btn_cancel "Cancel" width:60 align:#right

	on ConvertB2HDRI_MakeTXConverterRollout open do (
		if (convertB2HDRI_Rollout.check_convertEXR.checked) do (
			local tmpPath=convertB2HDRI_Rollout.convertPath
			if (tmpPath!=undefined) do (
				if (doesFileExist tmpPath) do (
					edit_path.text=tmpPath
					edit_path.enabled=false
				)
			)
		)
	)

	on btn_path pressed do (
		local toolPath=getOpenFileName filename:edit_path.text \
								types:"Executable File (maketx.exe)|maketx.exe"
		if (toolPath!=undefined) do (
			edit_path.text=toolPath
		)
	)

	on btn_set pressed do (
		convertB2HDRI_Rollout.convertPath=edit_path.text
		destroyDialog ConvertB2HDRI_MakeTXConverterRollout
	)

	on btn_cancel pressed do (
		convertB2HDRI_Rollout.cancelled=true
		destroyDialog ConvertB2HDRI_MakeTXConverterRollout
	)
)

--Just check if there is a valid converted to EXR file and return it.
--If EXR file couldn't be found in the same place like the original file then returns the original one .
fn convertB2HDRI_img2tiledexr imgpath=(
	local fullImgPath = mapPaths.getFullFilePath imgpath
	if ((classof fullImgPath)==String and fullImgPath != "") then (
		if ((stricmp (getFilenameType fullImgPath) ".exr")!=0) then (
			outpath=(getFilenamePath fullImgPath)+(getFilenameFile fullImgPath)+".exr"
		)
		else (
			outpath=fullImgPath
		)

		if (doesFileExist outpath) then (
			outpath
		)
		else (
			if (convertB2HDRI_ConverterErrors!=undefined) do (
				convertB2HDRI_ConverterErrors+=1
			)
			convertB2HDRI_ErrorsInTXExisting+=1
			format "Image % does not exist.\n" outpath
			fullImgPath
		)
	)
	else (
		if (fullImgPath=="") do (
			if (convertB2HDRI_ConverterErrors!=undefined) do (
				convertB2HDRI_ConverterErrors+=1
			)
			convertB2HDRI_ErrorsInTXExisting+=1
			format "Image % does not exist.\n" imgpath
		)
		imgpath
	)
)

--Just check if there is a valid converted to TX file and return it.
--If TX file couldn't be found in the same place like the original file then returns the original one .
fn convertB2HDRI_img2TX imgpath=(
	local fullImgPath = mapPaths.getFullFilePath imgpath
	if ((classof fullImgPath)==String and fullImgPath != "") then (
		if ((stricmp (getFilenameType fullImgPath) ".tx")!=0) then (
			outpath=(getFilenamePath fullImgPath)+(getFilenameFile fullImgPath)+".tx"
		)
		else (
			outpath=fullImgPath
		)

		if (doesFileExist outpath) then (
			outpath
		)
		else (
			if (convertB2HDRI_ConverterErrors!=undefined) do (
				convertB2HDRI_ConverterErrors+=1
			)
			convertB2HDRI_ErrorsInTXExisting+=1
			format "Image % does not exist.\n" outpath
			fullImgPath
		)
	)
	else (
		if (fullImgPath=="") do (
			if (convertB2HDRI_ConverterErrors!=undefined) do (
				convertB2HDRI_ConverterErrors+=1
			)
			convertB2HDRI_ErrorsInTXExisting+=1
			format "Image % does not exist.\n" imgpath
		)
		imgpath
	)
)

fn convertB2HDRI_Texmap texmap=(
	if (texmap!=undefined and (classof texmap)==Bitmaptexture) then (
		local tex=undefined
		local mapFileNameIsValid=(texmap.fileName != undefined and texmap.fileName != "")
		--tex.gamma=1/2.2
		--tex.color_space=3 --Lele: set VRayBitmap's Color space to "From Max"

		convertB2HDRI_Rollout.replaceImgCounter = convertB2HDRI_Rollout.replaceImgCounter + 1
		convertB2HDRI_Rollout.prog_convert.value = 100.*convertB2HDRI_Rollout.replaceImgCounter/convertB2HDRI_Rollout.replaceImgNums

		if (convertB2HDRI_ConvertEXR) then (
			--Here we would like to create VRayBitmap texture with Bitmaptexture file converted to EXR/TX bitmap file.
			convertB2HDRI_ErrorsInTXExisting=0
			local convertB2HDRI_ConvertLinear=convertB2HDRI_Rollout.convertLinear

			local resultHDRIMapName=undefined
			if useMakeTx then
				resultHDRIMapName=if(mapFileNameIsValid) then convertB2HDRI_img2TX texmap.fileName else undefined
			else
				resultHDRIMapName=if(mapFileNameIsValid) then convertB2HDRI_img2tiledexr texmap.fileName else undefined

			--If there isn't successful file conversion to EXR/TX or Bitmaptexture file name is not valid,
			--the original Bitmaptexture won't be replaced with VRayBitmap
			if (convertB2HDRI_ErrorsInTXExisting==0 and resultHDRIMapName!=undefined) do (
				tex=VRayBitmap()
				tex.name=texmap.name+"_VRay"
				tex.HDRIMapName=resultHDRIMapName
				tex.color_space = 1 -- Inverse gamma; set this after setting HDRIMapName so as to override any automatic gamma detection in VRayBitmap
				if (tex.HDRIMapName!=undefined) do (
					local gamma=vrayGetBitmapGamma texmap
					if (gamma!=undefined) then (
						-- If we used img2tiledexr for conversion, we need to correct the gamma specified in the Bitmap texture with
						-- the gamma that was applied when converting the image.
						if not useMakeTx then (
							-- Determine the gamma correction that was applied to the file when converting it
							local savedGamma=1.0
							if convertB2HDRI_ConvertLinear=="on" then savedGamma=2.2 -- We have applied 2.2 gamma when converting
							else if convertB2HDRI_ConvertLinear=="off" then savedGamma=1.0 -- We have not applied any gamma when converting
							else (
								-- Auto mode - we have applied 1.0 gamma for .exr/.hdr images and 2.2 gamma for everything else
								local isHDRI=(((stricmp (getFilenameType texmap.fileName) ".exr")==0) OR ((stricmp (getFilenameType texmap.fileName) ".hdr")==0))
								if isHDRI then savedGamma=1.0
								else savedGamma=2.2
							)

							-- Correct the gamma specified in the bitmap with the one that was applied during conversion.
							gamma=gamma/savedGamma
						)
						tex.gamma=1.0/gamma
					)
				)
			)
		)
		else (
			--Here we would like to create VRayBitmap texture without Bitmaptexture file convertion.
			tex=VRayBitmap()
			tex.name=texmap.name+"_VRay"
			if (mapFileNameIsValid) then (
				tex.HDRIMapName=texmap.fileName
			) else (
				format "Image path for % does not exist.\n" texmap
			)

			tex.color_space = 1 -- Inverse gamma; set this after setting HDRIMapName so as to override any automatic gamma detection in VRayBitmap
			local gamma=vrayGetBitmapGamma texmap
			if (gamma!=undefined) then (
				tex.gamma=1.0/gamma
			)
		)


		if (tex!=undefined) then (
			tex.mapType=4
			tex.UVGen.blur=texmap.coords.blur
			tex.UVGen.mapping=texmap.coords.mapping
			tex.UVGen.mapChannel=texmap.coords.mapChannel
			tex.UVGen.mappingType=texmap.coords.mappingType
			tex.UVGen.UVW_Type=texmap.coords.UVW_Type
			tex.UVGen.U_Mirror=texmap.coords.U_Mirror
			tex.UVGen.V_Mirror=texmap.coords.V_Mirror
			tex.UVGen.U_Tile=texmap.coords.U_Tile
			tex.UVGen.V_Tile=texmap.coords.V_Tile
			tex.UVGen.showMapOnBack=texmap.coords.showMapOnBack
			tex.UVGen.Noise_On=texmap.coords.Noise_On
			tex.UVGen.Noise_Animate=texmap.coords.Noise_Animate
			tex.UVGen.realWorldScale=texmap.coords.realWorldScale
			tex.UVGen.realWorldHeight=texmap.coords.realWorldHeight
			tex.UVGen.realWorldWidth=texmap.coords.realWorldWidth
			tex.UVGen.phase=texmap.coords.phase
			tex.UVGen.U_Angle=texmap.coords.U_Angle
			tex.UVGen.V_Angle=texmap.coords.V_Angle
			tex.UVGen.W_Angle=texmap.coords.W_Angle
			tex.UVGen.Noise_Amount=texmap.coords.Noise_Amount
			tex.UVGen.Noise_Size=texmap.coords.Noise_Size
			tex.UVGen.Noise_Levels=texmap.coords.Noise_Levels
			tex.UVGen.Blur_Offset=texmap.coords.Blur_Offset
			tex.UVGen.u_tiling=texmap.coords.u_tiling
			tex.UVGen.v_tiling=texmap.coords.v_tiling
			tex.UVGen.u_offset=texmap.coords.u_offset
			tex.UVGen.v_offset=texmap.coords.v_offset

			--Convert crop/placement
			tex.cropplace_on = texmap.apply
			tex.cropplace_mode = texmap.cropPlace
			tex.cropplace_u = texmap.clipu
			tex.cropplace_v = texmap.clipv
			tex.cropplace_width = texmap.clipw
			tex.cropplace_height = texmap.cliph

			--Convert channel output
			tex.rgbOutput = texmap.rgbOutput
			tex.monoOutput = texmap.monoOutput
			tex.alphaSource = texmap.alphaSource

			--Convert output parameters including curve control
			replaceInstances tex.output (copy texmap.output)

			--Frees up all the memory used by the image file bitmap caches.
			--This is useful if memory is fragmented with a lot of different bitmaps and you want to have just the ones currently active reloaded.
			freescenebitmaps()
			--invokes the garbage collector without flush the undo system
			gc lite:true
		)
		tex
	)
	else (
		undefined
	)
)

fn convertB2HDRI_SubTex texmap = (
	if (texmap!=undefined) then (
		-- check if we have already converted this texture; if yes, just return
		-- the already converted one
		local i=findItem orig_bitmaptextures texmap
		if i>0 then return new_hdritexmaps[i]

		for i = 1 to (getNumSubTexmaps texmap) do (
			local tex=(convertB2HDRI_SubTex (getSubTexmap texmap i))
			if (tex!=undefined) do (
				setSubTexmap texmap i tex
			)
		)

		local new_tex = texmap
		if ((classof texmap)==Bitmaptexture) then (
			new_tex=convertB2HDRI_Texmap texmap
		)

		-- if converted, add to the list of converted textures
		if new_tex!=texmap then (
			append orig_bitmaptextures texmap
			append new_hdritexmaps new_tex
			return new_tex
		)
	)
	return undefined
)

fn convertB2HDRI_SubMtl material = (
	if (material!=undefined) do (
		for i=1 to (getNumSubMtls material) do (
			convertB2HDRI_SubMtl (getSubMtl material i)
		)

		for i=1 to (getNumSubTexmaps material) do (
			local tex=(convertB2HDRI_SubTex (getSubTexmap material i))
			if (tex!=undefined) do (setSubTexmap material i tex)
		)
	)
)

fn convertB2HDRI_ArrayParameter propArray = (
	if ((classof propArray)==ArrayParameter) then (
		for i=1 to propArray.count do (
			if (propArray[i]!=undefined) do (
				if ((superclassof propArray[i])==textureMap) then (
					hdriTex=convertB2HDRI_SubTex propArray[i]
					if (hdriTex!=undefined) do propArray[i]=hdriTex
				) else if((superclassof propArray[i])==material) then (
					convertB2HDRI_SubMtl propArray[i]
				) else convertB2HDRI_ArrayParameter propArray[i]
			)
		)
	)
)

fn convertB2HDRI_Objects obj = (
	if(obj != undefined) do (
		local specificObj
		local classOfObj = classof obj
		if ((superclassof obj)==light) then (
			if (classOfObj == miAreaLightOmni) then (
				specificObj = obj.Omni_Light
			)
			else if (classOfObj == miAreaLight) then (
				specificObj = obj.Target_Spot
			)
			else (
				specificObj = obj
			)
		)
		else (
			specificObj = obj
		)

		local listPropNames = getPropNames specificObj

		local hdriTex = undefined
		local propValue = undefined

		for propName in listPropNames do (
			if (isProperty specificObj propName) then (
				propValue = getProperty specificObj propName
				if ((superclassof propValue)==textureMap) then (
					hdriTex = convertB2HDRI_SubTex propValue
					if (hdriTex!=undefined) do setProperty specificObj propName hdriTex
				) else if((superclassof propValue)==material) then (
					convertB2HDRI_SubMtl propValue
				) else convertB2HDRI_ArrayParameter propValue
			)
		)
	)
)

fn convertB2HDRI_Node node applyOnObjects = (
	if isValidNode node then (
		convertB2HDRI_SubMtl node.material
		if (applyOnObjects) do (convertB2HDRI_Objects node.baseObject)
		--convert bitmaps of node modifiers
		for imod in node.modifiers do (
			convertB2HDRI_Objects imod
		)
	)
)

fn convertB2HDRI_RenderSettings = (
	if(vrayCheckProductionRenderer()) then (
		productRenderer = renderers.production
		listRenderSettingsNames = getPropNames productRenderer
		for rParamName in listRenderSettingsNames do (
			if (isProperty productRenderer rParamName) then (
				rParam = getProperty productRenderer rParamName
				if ((superclassof rParam)==textureMap) then (
					hdriTex = convertB2HDRI_SubTex rParam
					if (hdriTex!=undefined) do setProperty productRenderer rParamName hdriTex
				) else if ((superclassof rParam)==material) then (
					convertB2HDRI_SubMtl rParam
				) else convertB2HDRI_ArrayParameter rParam
			)
		)
	)
)

fn convertB2HDRI_Environment = (
	-- Convert Environment map
	local envtex=convertB2HDRI_SubTex environmentMap
	if (envtex!=undefined) do environmentMap=envtex

	-- Convert Atmosphere effects
	for iAtmos=1 to numAtmospherics do (
		currAtmospheric = getAtmospheric iAtmos
		listAtmosNames = getPropNames currAtmospheric

		for atmosName in listAtmosNames do (
			if (isProperty currAtmospheric atmosName) then (
				atmosParam = getProperty currAtmospheric atmosName
				if ((superclassof atmosParam)==textureMap) then (
					hdriTex = convertB2HDRI_SubTex atmosParam
					if (hdriTex!=undefined) do setProperty currAtmospheric atmosName hdriTex
				) else if ((superclassof atmosParam)==material) then (
					convertB2HDRI_SubMtl atmosParam
				) else convertB2HDRI_ArrayParameter atmosParam
			)
		)
	)

	-- Convert Environment effects
	for iEffect=1 to numEffects do (
		currEffect = getEffect iEffect
		listEffectNames = getPropNames currEffect
		for effectName in listEffectNames do (
			if (isProperty currEffect effectName) then (
				effectParam = getProperty currEffect effectName
				if ((superclassof effectParam)==textureMap) then (
					hdriTex = convertB2HDRI_SubTex effectParam
					if (hdriTex!=undefined) do setProperty currEffect effectName hdriTex
				) else if ((superclassof effectParam)==material) then (
					convertB2HDRI_SubMtl effectParam
				) else convertB2HDRI_ArrayParameter effectParam
			)
		)
	)
)

--The main function that visits scene objects and replace Bitmaptexture with corresponding VRayBitmap
--exrConvert:<true|false> - true->converts bitmaps files to EXR/TX files.
--applyOnSceneObjects:<true|false> -> true->allows Bitmaptextures directly assigned to scene nodes to be converted to VRayBitmap
fn VRayBitmap2VRayBitmap exrConvert: applyOnSceneObjects: =(
	convertB2HDRI_ConvertEXR=false
	if (exrConvert!=unsupplied) do (
		if ((classof exrConvert)!=BooleanClass) then (print "Expected Boolean for exrConvert:")
		else convertB2HDRI_ConvertEXR=exrConvert
	)

	local applyOnObjects=false
	if (applyOnSceneObjects!=unsupplied) do (
		applyOnObjects = applyOnSceneObjects
	)

	local listBmpTexs = getClassInstances bitmaptex processChildren:true
	if applyOnObjects then (
		-- applyOnSceneObjects set to true allows all Bitmaptextures instances in the scene to be replaced
		-- Disable scene redraw during the replacement in order to prevent 3ds Max from updating the viewports after every change
		with redraw off (
			for iTex in listBmpTexs do (
				new_tex=convertB2HDRI_Texmap iTex
				if new_tex!=undefined then (
					replaceinstances iTex new_tex
				)
				else format "Converting Bitmap % to VRayBitmap was unsuccessful\n" iTex
			)
		)
	) else (
		--here we must avoid Bitmaptextures directly assigned to scene nodes
		new_hdritexmaps=#()
		orig_bitmaptextures=#()
		listOfConvertedNodesHandles=#()

		-- Disable scene redraw during the replacement in order to prevent 3ds Max from updating the viewports after every change
		with redraw off (
			for iTex in listBmpTexs do (
				local listOfNodes =  (refs.dependentNodes iTex)
				for iNode in listOfNodes do (
					local i=findItem listOfConvertedNodesHandles iNode.handle
					if i == 0 do (
						convertB2HDRI_Node iNode applyOnObjects
						append listOfConvertedNodesHandles iNode.handle
					)
				)
			)

			for i=1 to meditMaterials.count do (
				local m=meditMaterials[i]
				if (m.superClassID==3072) then ( -- This is a material
					convertB2HDRI_SubMtl m
				) else ( -- This is a texture
					m=convertB2HDRI_SubTex m
					if (m!=undefined) then meditMaterials[i]=m
				)
				updateMTLInMedit meditMaterials[i]
			)

			convertB2HDRI_RenderSettings()
			convertB2HDRI_Environment()
		)
	)
)

rollout convertB2HDRI_Rollout "V-Ray Bitmap to VRayBitmap texmap converter" width: 460 height: 110 (
	label label_message "All scene materials' Bitmap texmaps will be converted to VRayBitmap texmap." width:400 height:13 align:#center offset:[0, 10]

	checkbox check_convertEXR "Convert bitmaps to tiled EXR/TX." checked:false width:400 align:#center offset:[0, 10]
	checkbox check_convertObjectsInScene "Convert All scene Objects' Bitmap texmaps to VRayBitmap texmap." checked:false width:400 align:#center

	progressbar prog_convert width:290 align:#left across:3 offset:[17, 0]
	button btn_start "Convert" width:60 align:#right offset:[83, 0]
	button btn_cancel "Cancel" width:60 align:#right

	label label_progress "" width:150 align:#left offset:[17, -12]

	local cancelled=false
	local convertPath=undefined
	local convertHalf=false
	local convertCompression="zip"
	local convertTilesize=64
	local convertLinear="auto"

	local replaceImgCounter=0
	local replaceImgNums=0

	on btn_start pressed do (
		convertB2HDRI_ConverterErrors=0
		cancelled=false

		if (check_convertEXR.checked) do (
			local ver=getMaxReleaseAsString()
			convertPath = getVRayInstallPath ver
			if useMakeTx then
				CreateDialog convertB2HDRI_MakeTXConverterRollout modal:true
			else
				CreateDialog convertB2HDRI_TEXRConverterRollout modal:true
		)
		if (NOT cancelled) do (
			if (check_convertEXR.checked) do (
				label_progress.text = "Converting in progress..."
				if useMakeTx then
					convertImgToTX()
				else
					convertImgToTiledEXR convertHalf convertCompression convertTilesize convertLinear
			)
			start = timeStamp()
			label_progress.text = "Replacing in progress..."
			replaceImgCounter=0
			replaceImgNums = (getclassinstances Bitmaptexture processChildren:true).count
			vrayBitmap2VRayBitmap exrConvert:check_convertEXR.checked applyOnSceneObjects:check_convertObjectsInScene.checked
			end = timeStamp()
			format "Replacing took % seconds\n" ((end - start) / 1000.0)
			if (convertB2HDRI_ConverterErrors>0) do (
				messageBox ("There were "+(convertB2HDRI_ConverterErrors as String)+" images that did not convert successfully to tiled EXR format.\n They are listed in MAXScript Listener.\n The original images were left in place.") title:"Tiled EXR conversion error"
			)
		)

		destroyDialog convertB2HDRI_Rollout
	)

	on btn_cancel pressed do (
		destroyDialog convertB2HDRI_Rollout
	)
)

--vrayBitmapToVRayBitmap is a script equivalent to 'V-Ray Bitmap to VRayBitmap texmap converter' dialog
--In order to use maxscript function you should specify two arguments if you don't want the function to be exectued with its parameters' default values:
--  txConvert: <true|false> - Converts bitmaps to tiled EXR/TX. The default value is false.
--                                      If you've desided to have texmap conversion to tiled EXR/TX - that means txConvert is set to be true - and conversion tool is
--                                      'img2tiledexr', 4 specific parameters that corresponds to 'Img2tiledexr tool conversion options' dialog should be initialised.
--                                      convertHalf:<true|false>.  The default value is false.
--                                      convertCompression:<"none"|"rle"|"zips"|"zip"|"piz"|"pxr24">.  The default value is "zip".
--                                      convertTilesize:<32|64|128>.  The default value is 64.
--                                      convertLinear:<"off"|"on"|"auto">.  The default value is "auto".
--                                      If you've missed to do initialization, the default values will be used.
--  applyOnSceneObjects: <true|false> - Converts All scene Objects' Bitmap texmaps to VRayBitmap texmap. false is a default value.

fn vrayBitmapToVRayBitmap txConvert:false applyOnSceneObjects:false
                        convertHalf:true convertCompression:"zip" convertTilesize:64 convertLinear:"auto"= (
	local convertPath=undefined
	convertB2HDRI_ConverterErrors=0
	if (txConvert) do (
		local ver=getMaxReleaseAsString()
		convertPath = getVRayInstallPath ver
		if useMakeTx then
			convertImgToTX()
		else
			convertImgToTiledEXR convertHalf convertCompression convertTilesize convertLinear
	)

	start = timeStamp()
	--convertB2HDRI_Rollout is used just for consistency, to keep correct value for convertLinear and prevent division by zero in convertB2HDRI_Texmap
	convertB2HDRI_Rollout.replaceImgCounter=0
	convertB2HDRI_Rollout.replaceImgNums = (getclassinstances Bitmaptexture processChildren:true).count
	convertB2HDRI_Rollout.convertLinear = convertLinear
	vrayBitmap2VRayBitmap exrConvert:txConvert applyOnSceneObjects:applyOnSceneObjects
	end = timeStamp()
	format "Replacing took % seconds\n" ((end - start) / 1000.0)
	if (convertB2HDRI_ConverterErrors>0) do (
		messageBox ("There were "+(convertB2HDRI_ConverterErrors as String)+" images that did not convert successfully to tiled EXR format.\n They are listed in MAXScript Listener.\n The original images were left in place.") title:"Tiled EXR conversion error"
	)
)

macroScript VRayProperties
	category:"VRay"
	buttontext:"V-Ray properties"
	tooltip:"Displays the VRay object or light properties"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (doVRayObjectProperties())
)

macroScript VRaySceneConverter
	category:"VRay"
	buttontext:"V-Ray scene converter"
	tooltip:"Convert all scene materials to VRayMtl and all raytraced shadows to VRay shadows"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (CreateDialog vraySceneConverterRollout modal:true)
)

macroScript VRayBitmap2VRayBitmapTexmapConverter
	category:"VRay"
	buttonText:"V-Ray Bitmap to VRayBitmap converter"
	tooltip:"Convert all scene materials' Bitmaps to VRayBitmap"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (CreateDialog convertB2HDRI_Rollout modal:true)
)

macroScript VRayMeshExport
	category:"VRay"
	buttontext:".vrmesh exporter"
	tooltip:"Exports the selected meshes to an external file"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (doVRayMeshExport())
)

macroScript VRayShowVFB
	category:"VRay"
	buttontext:"V-Ray VFB"
	tooltip:"Displays the last rendered V-Ray VFB, if is exists"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		r=renderers.production
		if(r!=undefined) do (
			cid=renderers.production.classid
			if (cid[1]==1941615238 and cid[2]==2012806412) do r.showLastVFB()
			if (cid[1]==1770671000 and cid[2]==1323107829) do r.V_Ray_settings.showLastVFB()
		)
	)
)

-- Menu bar V-Ray action items
macroScript VRayProxy
	category:"VRay"
	buttonText:"V-Ray Proxy"
	toolTip: "Create V-Ray Proxy"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayProxy)
)

macroScript VRayDecal
	category:"VRay"
	buttonText:"V-Ray Decal"
	toolTip: "Create V-Ray Decal"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayDecal)
)

macroScript VRayFur
	category:"VRay"
	buttonText:"V-Ray Fur"
	toolTip: "Create V-Ray Fur"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer() AND (superClassOf $ == GeometryClass))
	on isVisible do (checkVRayRenderer())

	on execute do (
		if($ == undefined) then warningToSelectGeometry "V-Ray Fur"

		local vrFur = undefined
		theHold.Begin()
		if(superClassOf $ == GeometryClass) then (
			vrFur = VRayFur sourceNode:$ pos:$.pos
			append $.children vrFur
			select vrFur
			setCommandPanelTaskMode #modify
		) else if(isKindOf $ ObjectSet) then (
			for obj in $ do (
				if(superClassOf obj == GeometryClass) do (
					vrFur = VRayFur sourceNode:obj pos:obj.pos
					append obj.children vrFur
				)
			)
			select vrFur
			setCommandPanelTaskMode #modify
		)
		else (
			print "Please select a geometry object to apply V-Ray Fur!"
		)
		theHold.Accept("V-Ray Fur")
	)
)

macroScript VRayVolumeGrid
	category:"VRay"
	buttonText:"V-Ray VolumeGrid"
	toolTip: "Create V-Ray VolumeGrid"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayVolumeGrid)
)

macroScript VRayPlane
	category:"VRay"
	buttonText:"V-Ray Plane"
	toolTip: "Create V-Ray Plane"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayPlane)
)

macroScript VRaySphere
	category:"VRay"
	buttonText:"V-Ray Sphere"
	toolTip: "Create V-Ray Sphere"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRaySphere)
)

macroScript VRayMetaball
	category:"VRay"
	buttonText:"V-Ray Metaball"
	toolTip: "Create V-Ray Metaball"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayMetaball)
)

macroScript VRayClipper
	category:"VRay"
	buttonText:"V-Ray Clipper"
	toolTip: "Create V-Ray Clipper"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayClipper)
)

macroScript VRayInstancer
	category:"VRay"
	buttonText:"V-Ray Instancer"
	toolTip: "Create V-Ray Instancer"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayInstancer)
)

macroScript VRayVolumeGrid
	category:"VRay"
	buttonText:"V-Ray VolumeGrid"
	toolTip: "Create V-Ray VolumeGrid"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayVolumeGrid)
)

macroScript VRayLight_Plane
	category:"VRay"
	buttonText:"V-Ray Plane Light"
	iconName: ":/VRayToolbar/PlaneLight"
	toolTip: "Create V-Ray Plane Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		setCurrentVRayLightCreationType 0
		StartObjectCreation VRayLight
	)
)

macroScript VRayLight_Dome
	category:"VRay"
	buttonText:"V-Ray Dome Light"
	iconName: ":/VRayToolbar/DomeLight"
	toolTip: "Create V-Ray Dome Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		setCurrentVRayLightCreationType 1
		StartObjectCreation VRayLight
	)
)

macroScript VRayLight_Sphere
	category:"VRay"
	buttonText:"V-Ray Sphere Light"
	iconName: ":/VRayToolbar/SphereLight"
	toolTip: "Create V-Ray Sphere Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		setCurrentVRayLightCreationType 2
		StartObjectCreation VRayLight
	)
)

macroScript VRayLight_Mesh
	category:"VRay"
	buttonText:"V-Ray Mesh Light"
	iconName: ":/VRayToolbar/MeshLight"
	toolTip: "Create V-Ray Mesh Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		setCurrentVRayLightCreationType 3
		StartObjectCreation VRayLight
	)
)

macroScript VRayLight_Disc
	category:"VRay"
	buttonText:"V-Ray Disc Light"
	iconName: ":/VRayToolbar/DiscLight"
	toolTip: "Create V-Ray Disc Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		setCurrentVRayLightCreationType 4
		StartObjectCreation VRayLight
	)
)

macroScript VRayIES
	category:"VRay"
	buttonText:"V-Ray IES Light"
	iconName: ":/VRayToolbar/IESLight"
	toolTip: "Create V-Ray IES Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if(renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayIES)
)

macroScript VRayAmbientLight
	category:"VRay"
	buttonText:"V-Ray Ambient Light"
	iconName: ":/VRayToolbar/AmbientLight"
	toolTip: "Create V-Ray Ambient Light"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayAmbientLight)
)

macroScript VRaySun
	category:"VRay"
	buttonText:"V-Ray Sun"
	iconName: ":/VRayToolbar/SunLight"
	toolTip: "Create V-Ray Sun"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRaySun)
)

macroScript VRayDomeCamera
	category:"VRay"
	buttonText:"V-Ray Dome Camera"
	toolTip: "Create V-Ray Dome Camera"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayDomeCamera)
)

fn vrayCreateVRayPhysicalCameraFromView = (
	--camera variable
	local c = undefined
	local wcol = (color 5 54 179)
	local targdist = viewport.GetFocalDistance()

	-- get viewport tm
	local viewfov = getVIewFOV()
	local cXform = if InverseHighPrecision == undefined then Inverse(viewport.getTM())
					else InverseHighPrecision(viewport.getTM())

	local viewportType = viewport.Gettype()
	theHold.Begin()
	c = VRayPhysicalCamera targeted:false isSelected:on wirecolor:wcol
	c.target_distance = targdist
	c.specify_fov = true
	c.fov = viewfov
	c.transform = cXform
	local viewportCamera = viewport.getCamera()
	if viewportCamera != undefined then (
		if (hasproperty viewportCamera "type") do (
			c.targeted = (viewportCamera.type == #target)
			--that workaround prevents crash when target camera has been created
			--but target node is missing. For example camera created via Targetcamera()
			--and aligned to viewport there isn't target node.
			--After that if we try to create camera from toolbar, it is expected viewportCamera
			--to have valid target in order to get its position. If viewportCamera.target is undefined
			--then the result is crash. The next implementation ensures viewportCamera to have
			--target node.
			if c.targeted and viewportCamera.target == undefined then (
				viewportCamera.type=#free
				viewportCamera.type=#target
			)
		)
		if (hasproperty viewportCamera "targeted") do (
			c.targeted = viewportCamera.targeted
			--that workaround prevents crash when target camera has been created
			--but target node is missing. For example camera created via Physical(), vrayPhysicalCamera()
			--or vraycreatevrayphysicalcamera() and aligned to viewport there isn't target node.
			--After that if we try to create camera from toolbar, it is expected viewportCamera
			--to have valid target in order to get its position. If viewportCamera.target is undefined
			--then the result is crash. The next implementation ensures viewportCamera to have
			--target node.
			if c.targeted and viewportCamera.target == undefined then (
				viewportCamera.targeted=false
				viewportCamera.targeted=true
			)
		)
	) else (
		if (viewportType == #view_persp_user) do c.targeted = true
	)
	if c.targeted do (
		c.target.wirecolor = wcol
		if viewportCamera != undefined do (
			c.target.pos = viewportCamera.target.pos
			vpTController = viewportCamera.transform.controller
			vrayTController = c.transform.controller
			if vrayTController != undefined and vpTController != undefined do (
				--Transfer of LookAt controller data
				vrayTController.UseTargetAsUpNode = vpTController.UseTargetAsUpNode
				vrayTController.Axis = vpTController.Axis
				vrayTController.Flip = vpTController.Flip
				vrayTController.Position = vpTController.Position
				vrayTController.Roll_Angle = vpTController.Roll_Angle
				vrayTController.Scale = vpTController.Scale
			)
		)
	)
	viewport.setcamera c
	theHold.Accept "Create V-Ray Physical Camera from View"
	-- clears the local variables
	viewfov = undefined
	cXform  = undefined

	c
)

macroScript VRayPhysicalCamera
	category:"VRay"
	buttonText:"V-Ray Physical Camera"
	toolTip: "Create V-Ray Physical Camera"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)
	on IsEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		resultCamera = vrayCreateVRayPhysicalCameraFromView()
		if resultCamera == undefined then StartObjectCreation VRayPhysicalCamera
	)
)

macroScript VRayLightMeter
	category:"VRay"
	buttonText:"V-Ray Light Meter"
	toolTip: "Create V-Ray Light Meter"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayLightMeter)
)

macroScript VRayBPTracer
	category:"VRay"
	buttonText:"V-Ray BPTracer"
	toolTip: "Create V-Ray BPTracer"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayBPTracer)
)

macroScript VRayStereoscopic
	category:"VRay"
	buttonText:"V-Ray Stereoscopic"
	toolTip: "Create V-Ray Stereoscopic"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayStereoscopic)
)

macroScript VRayStereoRig
	category:"VRay"
	buttonText:"V-Ray StereoRig"
	toolTip: "Create V-Ray StereoRig"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (StartObjectCreation VRayStereoRig)
)

macroScript VRayDisplacementMod
	category:"VRay"
	buttonText:"V-Ray Displacement Mod"
	toolTip: "V-Ray Displacement Mod"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer() AND (ValidModifier $ VRayDisplacementMod))
	on isVisible do (checkVRayRenderer())

	on execute do (
		if ($==undefined) do (warningToSelectGeometry "Displacement Modifier")

		theHold.begin()
		if ((superClassOf $)==GeometryClass) then (
			if (ValidModifier $ VRayDisplacementMod) do (
				addModifier $ (VRayDisplacementMod())
			)
		) else if (isKindOf $ ObjectSet) then (
			for obj in $ do (
				if (((superClassOf obj)==GeometryClass) AND (ValidModifier obj VRayDisplacementMod)) do (
					addModifier obj (VRayDisplacementMod())
				)
			)
		)
		else (
			print "Please select a geometry object to apply Displacement Modifier!"
		)
		theHold.Accept("V-Ray DisplacementMod")
	)
)

macroScript VRayEnmeshMod
	category:"VRay"
	buttonText:"V-Ray EnMesh Mod"
	toolTip: "V-Ray EnMesh Modifier"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer() AND (ValidModifier $ VRayEnmeshMod))
	on isVisible do (checkVRayRenderer())

	on execute do (
		if ($==undefined) do (warningToSelectGeometry "V-Ray EnMesh Modifier")

		theHold.begin()
		if ((superClassOf $)==GeometryClass) then (
			if (ValidModifier $ VRayEnmeshMod) do (
				addModifier $ (VRayEnmeshMod())
			)
		) else if (isKindOf $ ObjectSet) then (
			for obj in $ do (
				if (((superClassOf obj)==GeometryClass) AND (ValidModifier obj VRayEnmeshMod)) do (
					addModifier obj (VRayEnmeshMod())
				)
			)
		)
		else (
			print "Please select a geometry object to apply V-Ray EnMesh Modifier!"
		)
		theHold.Accept("V-Ray EnMesh Mod")
	)
)

macroScript VRayOrnatrixMod
	category:"VRay"
	buttonText:"V-Ray Ornatrix Mod"
	toolTip: "V-Ray Ornatrix Mod"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer() AND (ValidModifier $ VRayOrnatrixMod))
	on isVisible do (checkVRayRenderer())

	on execute do
	(
		theHold.Begin()
		if ((superClassOf $)==GeometryClass) then (
			if (ValidModifier $ VRayOrnatrixMod) do (
				addModifier $ (VRayOrnatrixMod())
			)
		) else if (isKindOf $ ObjectSet) then (
			for obj in $ do (
				if (((superClassOf obj)==GeometryClass) AND (ValidModifier obj VRayOrnatrixMod)) do (
					addModifier obj (VRayOrnatrixMod())
				)
			)
		)
		else (
			warningToSelectGeometry "Ornatrix Modifier"
		)
		theHold.Accept("V-Ray Ornatrix Mod")
	)
)

macroScript VRayHairFarmMod
	category:"VRay"
	buttonText:"V-Ray HairFarm Mod"
	toolTip: "V-Ray HairFarm Mod"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer() AND (ValidModifier $ VRayHairFarmMod))
	on isVisible do (checkVRayRenderer())

	on execute do (
		if ($==undefined) do (warningToSelectGeometry "V-Ray HairFarm")
		theHold.Begin()
		if ((superClassOf $)==GeometryClass) then (
			if (ValidModifier $ VRayHairFarmMod) do (
				addModifier $ (VRayHairFarmMod())
			)
		) else if (isKindOf $ ObjectSet) then (
			for obj in $ do (
				if (((superClassOf obj)==GeometryClass) AND (ValidModifier obj VRayHairFarmMod)) do (
					addModifier obj (VRayHairFarmMod())
				)
			)
		)
		else (
			print "Please select a geometry object to apply V-Ray HairFarm!"
		)
		theHold.Accept("V-Ray HairFarm")
	)
)

macroScript VRayCameraLister
	category:"VRay"
	buttonText:"V-Ray Camera Lister"
	toolTip: "V-Ray Camera lister tool"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		if (vrayCameraLister!=undefined) do (
			vrayCameraLister()
		)
	)

	on closeDialogs do
	(
		if (vrayDestroyCameraLister!=undefined) do (
			vrayDestroyCameraLister()
		)
	)

	on isChecked return vrayCameraListerIsOpen()
)

-- Macroscript for the Viewport IPR button - visible when the current renderer is V-Ray/V-Ray GPU and we
-- are currently not running Viewport IPR
macroscript VRayViewportIPR
	category:"VRay"
	buttontext:"V-Ray Viewport IPR"
	tooltip:"Toggle V-Ray Viewport IPR"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	-- Returns the current renderer index to be used with vrayViewportIPRControl
	fn getRendererType = (
		local result = 0
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			if (cid[1]==1770671000 and cid[2]==1323107829) do (result = 1)
		)
		result
	)

	on isVisible do (
		if (checkVRayRenderer()) then (
			if (vrayViewportIPRControl!=undefined) do ((vrayViewportIPRControl 0 0) or (vrayViewportIPRControl 1 0))
		)
		else (
			false
		)
	)

	on isEnabled do (
		if (checkVRayRenderer()) then (
			if (vrayViewportIPRControl!=undefined) do ((vrayViewportIPRControl 0 1) or (vrayViewportIPRControl 1 1))
		)
		else (
			false
		)
	)

	on isChecked do (
		if (checkVRayRenderer()) then (
			if (vrayViewportIPRControl!=undefined) do ((vrayViewportIPRControl 0 2) or (vrayViewportIPRControl 1 2))
		)
		else (
			false
		)
	)

	on Execute do (
		if (checkVRayRenderer()) do (
			if (vrayViewportIPRControl!=undefined) do (
				if (vrayViewportIPRControl (getRendererType()) 2) then (
					vrayViewportIPRControl (getRendererType()) 4
				)
				else (
					vrayViewportIPRControl (getRendererType()) 3
				)
			)
		)
	)
)

-- Debug shading
-- Set the specified mode. If the mode is already selected - turn off debug shading
fn setVRayDebugShadingMode mode=(
	local res=vfbcontrol #debugshading #debugshadingmode #debugshadinglockedselection
	if (res!=undefined and res.count==3) then (
		if (res[2]==mode and res[3]!=1) then (
			-- clicking on the current mode should just invert enabled.
			vfbcontrol #debugshading (not (res[1]>0))
		) else (
			-- different mode - set the mode and enable debug shading
			vfbcontrol #debugshading true
			vfbcontrol #debugshadingmode (mode)
		)
		true
	) else (
		false
	)
)

-- Macro scripts for the various modes.
macroscript VRayIsolateSelect
	category:"VRayDebugShading"
	buttontext:"Isolate Selected"
	tooltip:"V-Ray Viewport Debug Shading Isolate Selected"
(
	-- the debug shading mode of this macroscript
	local ourMode=0

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)

	on isChecked do (
		-- special case - we have to check for locked selection too
		if (vfbcontrol!=undefined) then (
			local lockedSel=vfbcontrol #debugshadinglockedselection
			local isLocked=(classof lockedSel==Array and lockedSel[1]!=0)
			if (getVRayDebugShadingChecked != undefined) then (
				(getVRayDebugShadingChecked (ourMode)) and not isLocked
			) else (
				false
			)
		) else (
			false
		)
	)

	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayIsolateSelectLocked
	category:"VRayDebugShading"
	buttontext:"Isolate Locked Selection"
	tooltip:"V-Ray Viewport Debug Shading Isolate Locked Selection"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)

	on isChecked do (
		if (vfbcontrol!=undefined) then (
			res=vfbcontrol #debugshadinglockedselection
			if (classof res==Array) then (
				res[1] != 0
			) else (
				false
			)
		) else (
			false
		)
	)

	on Execute do (
		res=vfbcontrol #debugshadinglockedselection
		if (res != undefined) do
			vfbcontrol #debugshadinglockedselection (not (res[1]>0))
	)
)

macroscript VRayDebugShadingLighting
	category:"VRayDebugShading"
	buttontext:"Lighting"
	tooltip:"V-Ray Viewport Debug Shading Lighting"
(
	-- the debug shading mode of this macroscript
	local ourMode=1

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayDebugShadingAO
	category:"VRayDebugShading"
	buttontext:"Ambient Occlusion"
	tooltip:"V-Ray Viewport Debug Shading Ambient Occlusion"
(
	-- the debug shading mode of this macroscript
	local ourMode=2

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayDebugShadingWireframe
	category:"VRayDebugShading"
	buttontext:"Wireframe"
	tooltip:"V-Ray Viewport Debug Shading Wireframe"
(
	-- the debug shading mode of this macroscript
	local ourMode=3

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayDebugShadingNormals
	category:"VRayDebugShading"
	buttontext:"Normals"
	tooltip:"V-Ray Viewport Debug Shading Normals"
(
	-- the debug shading mode of this macroscript
	local ourMode=4

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayDebugShadingUVs
	category:"VRayDebugShading"
	buttontext:"UVs"
	tooltip:"V-Ray Viewport Debug Shading UVs"
(
	-- the debug shading mode of this macroscript
	local ourMode=5

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRayDebugShadingBary
	category:"VRayDebugShading"
	buttontext:"Barycentric coordinates"
	tooltip:"V-Ray Viewport Debug Shading Barycentric coordinates"
(
	-- the debug shading mode of this macroscript
	local ourMode=6

	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	-- Return true if the debug shading menus should be enabled - only while IPR is running
	fn getVRayDebugShadingEnabled=(
		if (vrayIsRenderingIPR!=undefined) then
			vrayIsRenderingIPR()
		else
			false
	)

	-- Return true if the menu item for the specified mode should be checked
	fn getVRayDebugShadingChecked mode=(
		local res=vfbcontrol #debugshading #debugshadingmode
		(classof res==Array) and (res.count==2) and (res[1]!=0) and (res[2]==mode)
	)

	on isVisible do (checkVRayRenderer())
	on isEnabled do (
		if (getVRayDebugShadingEnabled != undefined) then (
			getVRayDebugShadingEnabled() != 0
		) else (
			false
		)
	)
	on isChecked do (
		if (getVRayDebugShadingChecked != undefined) then (
			getVRayDebugShadingChecked (ourMode)
		)
		else (
			false
		)
	)
	on Execute do (setVRayDebugShadingMode (ourMode))
)

macroscript VRaySubmitToChaosCloud
	category:"VRay"
	buttonText:"Submit to Chaos Cloud"
	toolTip: "Submit to Chaos Cloud rendering"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		if (vrayCloudSubmit!=undefined) do (
			vrayCloudSubmit()
		)
	)
)

macroscript VRayChaosCosmosBrowser
	category:"VRay"
	buttonText:"Chaos Cosmos browser"
	toolTip: "Cosmos browser"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		if (showCosmosBrowser!=undefined) then (showCosmosBrowser()) else (print "Cannot find Cosmos browser plugin")
	)
)

--Convert scene materials to .vrmat
--@param onlySelectedMtls -> true - converts only selected materials
--                                     -> false- converts all scene materials
--@param toOneVRmat -> true - all vray materials are converted to one .vrmat file
--                              -> false - all vray material are converted to separated .vrmat files
fn convertSceneMaterials onlySelectedMtls toOneVRmat =
(
	local listMtls = if onlySelectedMtls then (for iNode in selection collect iNode.material) else sceneMaterials
	if toOneVRmat then (
		local vrmatFilePath=getSaveFileName caption:"VRMAT Export Path" types:"VRMAT files (*.vrmat)|*.vrmat"
		if (vrmatFilePath != undefined) do (
			format "Exporting material...\n"
			format "saving vrmat to %\n" vrmatFilePath

			local saveDir = getFilenamePath vrmatFilePath
			local f = openFile vrmatFilePath mode:"w"

			openVismatTag f

			for i=1 to listMtls.count do (
				print listMtls[i]
				clearArrBitMapTxtPaths()
				dumpSelectedMaterial listMtls[i] f vismatmode:"ONLYONEVISMAT"
				createBmpFilesInVismatFolder saveDir
			)

			closeVismatTag f
			flush f
			close f

			format "Done\n"
		)
	)
	else (
		local saveDir = getSavePath caption:"VRMAT Export Directory"
		if (saveDir != undefined) do (
			for i=1 to listMtls.count do (
				print listMtls[i]
				local iMat = listMtls[i]
				local matSaveDir = saveDir + "\\" + iMat.name
				makeDir matSaveDir all:true
				local fileName =  (matSaveDir + "\\" + iMat.name + ".vrmat")

				format "Exporting material...\n"
				format "saving vrmat to %\n" fileName

				local f = openFile fileName mode:"w"

				clearArrBitMapTxtPaths()
				openVismatTag f
				dumpSelectedMaterial iMat f
				closeVismatTag f
				createBmpFilesInVismatFolder matSaveDir

				flush f
				close f

				format "Done\n"
			)
		)
	)
)

macroscript ConvertSelectedObjsMtlsToSingleVRMAT
	category:"VRay"
	buttonText:"to a single .vrmat file"
	toolTip: "Convert selectet objects materials to single .vrmat file"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		convertSceneMaterials true true
	)
)

macroscript ConvertSelectedObjsMtlsToSeparateVRMAT
	category:"VRay"
	buttonText:"to separate .vrmat files"
	toolTip: "Convert selectet objects materials to separate .vrmat files"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		convertSceneMaterials true false
	)
)

macroscript ConvertAllSceneMtlsToSingleVRMAT
	category:"VRay"
	buttonText:"to a single .vrmat file"
	toolTip: "Convert all scene materials to single .vrmat file"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		convertSceneMaterials false true
	)
)

macroscript ConvertAllSceneMtlsToSeparateVRMAT
	category:"VRay"
	buttonText:"to separate .vrmat files"
	toolTip: "Convert all scene materials to separate .vrmat files"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		convertSceneMaterials false false
	)
)

--Convert material to .vrmat
--@param mtl - selected/existed material
--@param saveDir - path for the .vrmat file which name is constructed based on material name and .vrmat extension
fn convertMaterialToVRMATfile mtl saveDir = (
	if (saveDir != undefined and mtl != undefined) do (
		print mtl
		saveDir = saveDir + "\\" + mtl.name
		makeDir saveDir all:true
		local fileName =  (saveDir + "\\" + mtl.name + ".vrmat")

		format "Exporting material...\n"
		format "saving vrmat to %\n" fileName

		local f = openFile fileName mode:"w"

		clearArrBitMapTxtPaths()
		openVismatTag f
		dumpSelectedMaterial mtl f
		closeVismatTag f
		createBmpFilesInVismatFolder saveDir

		flush f
		close f

		format "Done\n"
	)
)

macroscript ConvertPickedFromMtlEditorToVRMAT
	category:"VRay"
	buttonText:"Pick from Material Editor"
	toolTip: "Pick material from Material Editor and convert it to .vrmat file"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local mtl = MaterialBrowseDlg()
		local saveDir = getSavePath caption:"VRMAT Export Directory"

		convertMaterialToVRMATfile mtl saveDir
	)
)

macroscript HelpGetStartedWithVRay
	category:"VRay"
	buttonText:"Get started with V-Ray"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		shellLaunch  "https://www.chaos.com/vray/3ds-max/learn" ""
	)
)

macroscript HelpDocs
	category:"VRay"
	buttonText:"Help docs"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		shellLaunch  "https://docs.chaos.com/display/VMAX/V-Ray+for+3ds+Max+Help" ""
	)
)

macroscript HelpSubmitRequest
	category:"VRay"
	buttonText:"Submit a support request"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		shellLaunch  "https://support.chaos.com/hc/en-us/requests/new" ""
	)
)

macroscript HelpChaosForum
	category:"VRay"
	buttonText:"Chaos Forum"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		shellLaunch  "https://forums.chaos.com/" ""
	)
)

macroscript HelpRegisterVRayMenus
	category:"VRay"
	buttonText:"Register V-Ray menus"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		updateVRayMenus()
	)
)

macroscript HelpSetDefaultUI
	category:"VRay"
	buttonText:"Set default MAX V-Ray UI"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local defaultUIScheme=pathconfig.appendPath (getdir #UI) "DefaultUI.ui"
		loadCUIScheme defaultUIScheme
		local defaultsPath = pathconfig.AppendPath (getdir #maxroot) (Sysinfo.getMaxLanguage())[5]
		local defaultsPathMAXvray = pathconfig.AppendPath defaultsPath "defaults\\MAX.vray\\"
		setIniSetting (GetMAXIniFile()) "Directories" "Defaults" defaultsPathMAXvray
	)
)

macroscript VRaySetLocalLicenseSettings
	category:"VRay"
	buttonText:"Set local license settings"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		if (vrayShowLocalLicenseServer!=undefined) then (vrayShowLocalLicenseServer()) else (print "Cannot open V-Ray local license server dialog")
	)
)

macroscript VRayManageChaosLicenseServer
	category:"VRay"
	buttonText:"Manage Chaos License Server"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		shellLaunch  "http://localhost:30304/#" ""
	)
)

fn assignVRAYTypeMtl vrmtl = (
	if(vrmtl!=undefined) do (
		local activeslot = medit.GetActiveMtlSlot()
		MatEditor.Open()
		medit.PutMtlToMtlEditor vrmtl activeslot

		if(selection.count>0) do (
			for iNode in selection do (
				if(superClassOf iNode == GeometryClass) then (
					iNode.material = vrmtl
					for iChild in iNode.children do (
						iChild.material = vrmtl
					)
				) else if(isKindOf iNode ObjectSet) do (
					for obj in iNode do (
						if(superClassOf obj == GeometryClass) do (
							obj.material = vrmtl
						)
					)
				)
			)
		)

		if(MatEditor.mode==#advanced) do showMtlSlotInSME activeslot
	)
)

macroscript VRayMtl
	category:"VRay"
	buttonText:"VRayMtl"
	iconName:":/VRayToolbar/VrayMtl"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRayMtl
		assignVRAYTypeMtl vrmtl
	)
)

macroscript VRayFastSSS2
	category:"VRay"
	buttonText:"VRayFastSSS2"
	iconName:":/VRayToolbar/VrayFastSSS"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRayFastSSS2
		assignVRAYTypeMtl vrmtl
	)
)

macroscript VRayHairNextMtl
	category:"VRay"
	buttonText:"VRayHairNextMtl"
	iconName:":/VRayToolbar/VrayHair"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRayHairNextMtl
		assignVRAYTypeMtl vrmtl
	)
)

macroscript VRayALSurfaceMtl
	category:"VRay"
	buttonText:"VRayALSurfaceMtl"
	iconName:":/VRayToolbar/VrayALSurface"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRayALSurfaceMtl
		assignVRAYTypeMtl vrmtl
	)
)

macroscript VRay2SidedMtl
	category:"VRay"
	buttonText:"VRay2SidedMtl"
	iconName:":/VRayToolbar/Vray2Sided"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRay2SidedMtl
		assignVRAYTypeMtl vrmtl
	)
)

macroscript VRayBlendMtl
	category:"VRay"
	buttonText:"VRayBlendMtl"
	iconName:":/VRayToolbar/VrayBlendMtl"
(
	-- This check implementation is present in all maxscripts, to make them independent on other scripts
	fn checkVRayRenderer = (
		local enabled=false
		if (renderers.production!=undefined) do (
			cid=renderers.production.classid
			enabled=((cid[1]==1941615238) and (cid[2]==2012806412) or (cid[1]==1770671000) and (cid[2]==1323107829))
		)
		enabled
	)

	on isEnabled do (checkVRayRenderer())
	on isVisible do (checkVRayRenderer())

	on execute do (
		local vrmtl = CreateInstance VRayBlendMtl
		assignVRAYTypeMtl vrmtl
	)
)