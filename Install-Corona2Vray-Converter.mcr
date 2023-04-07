/*
	Vray2Corona Converter
	by MastaMan
	Installer file
	
	https://3dground.net/
*/

fn installCorona2VrayConverter = (
	local currScript = getThisScriptFileName()	
	local pth = getFileNamePath currScript
	local scr = pth + "Corona2Vray-Converter.ms"
	
	if (not doesFileExist scr) do return messageBox (scr + " not found!\nPlease download script from GitHub and try again!") title: "Error!"
	
	n = "\n"
	ex = "macroScript RunCoronaToVrayConverter" + n
	ex += "category:\"[3DGROUND]\"" + n
	ex += "toolTip:\"Corona2Vray\"" + n
	ex += "buttontext:\"Corona2Vray\"" + n
	ex += "(" + n
	ex += "on execute do (" + n
	ex += "try(fileIn(@\"" + scr + "\")) catch(messageBox \"Script not found! Please reinstall script!\" title: \"Warning!\")" + n
	ex += ")" + n
	ex += ")" + n
	
	execute ex
	
	m = "Corona2Vray Converter installed success!" + n
	m += "You can find it in [3DGROUND] category."
	
	messageBox m title: "Installed" beep: false
)


installCorona2VrayConverter()