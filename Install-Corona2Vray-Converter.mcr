/*
	Vray2Corona Converter
	by MastaMan
	Installer file
	
	https://3dground.net/
*/

fn installVray2CoronaConverter = (
	local currScript = getThisScriptFileName()	
	local pth = getFileNamePath currScript
	local scr = pth + "Vray2Corona-Converter.ms"
	
	if (not doesFileExist scr) do return messageBox (scr + " not found!\nPlease download script from GitHub and try again!") title: "Error!"
	
	n = "\n"
	ex = "macroScript RunVrayToCoronaConverter" + n
	ex += "category:\"[3DGROUND]\"" + n
	ex += "toolTip:\"Vray2Corona\"" + n
	ex += "buttontext:\"Vray2Corona\"" + n
	ex += "(" + n
	ex += "on execute do (" + n
	ex += "try(fileIn(@\"" + scr + "\")) catch(messageBox \"Script not found! Please reinstall script!\" title: \"Warning!\")" + n
	ex += ")" + n
	ex += ")" + n
	
	execute ex
	
	m = "Vray2Corona Converter installed success!" + n
	m += "You can find it in [3DGROUND] category."
	
	messageBox m title: "Installed" beep: false
)


installVray2CoronaConverter()