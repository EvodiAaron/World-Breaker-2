const express = require('express');
const app = express();
const bodyParser = require('body-parser');
const busboy = require('connect-busboy');
const path = require('path');
const fs = require('fs');

// ensure that server can read body of requests
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({
    extended: false
}));
app.use(busboy());
app.use(express.json());

let port = 80
app.listen(port, () => {
    console.log("Server initialised. Listening to port " + port)
});


app.get('/repositories/:repository/:filename', (request, response) => {
    
    response.sendFile(path.resolve(__dirname + '/../' + request.params.repository + '/' + request.params.filename), function (error) { 
        if(error)   { 
            response.status(404).send("File not found")
        }
        else    { 
            console.log("Downloaded: " + request.params.repository + '\\' + request.params.filename); 
        } 
    }); 
});

// return files in repository
app.get('/repositories/:repository', (request, response) => {
    let GetContentsFromFolder = function(dir) {

        var filesystem = require("fs");
        var results = [];
    
        filesystem.readdirSync(dir).forEach(function(file) {
    
            file = dir + '/'+file;
            var stat = filesystem.statSync(file);
    
            if (stat && stat.isDirectory()) {
                results = results.concat(GetContentsFromFolder(file))
            } else results.push(file);
    
        });
    
        return results;
    };

    try {
        let files = GetContentsFromFolder(path.resolve(__dirname + '/../' + request.params.repository))

        pathPrefix = path.resolve(__dirname + '/../') + "\\" + request.params.repository + "/"

        let filesShortened = []
        for(file in files)  {
            let temp = files[file].replace(pathPrefix, "")
            temp = temp.replace(/\//g, "%2F")

            filesShortened.push(temp)
        }
        
        response.status(200).send(filesShortened)
    }
    catch(error)   {
        response.status(404).send("Repository not found")
    }
    
});