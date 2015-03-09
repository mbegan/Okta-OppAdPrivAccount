package com.varian.it.scim;

import com.okta.scim.server.capabilities.UserManagementCapabilities;
import com.okta.scim.server.exception.DuplicateGroupException;
import com.okta.scim.server.exception.EntityNotFoundException;
import com.okta.scim.server.exception.OnPremUserManagementException;
import com.okta.scim.server.service.SCIMService;
import com.okta.scim.util.model.PaginationProperties;
import com.okta.scim.util.model.SCIMFilter;
import com.okta.scim.util.model.SCIMGroup;
import com.okta.scim.util.model.SCIMGroupQueryResponse;
import com.okta.scim.util.model.SCIMUser;
import com.okta.scim.util.model.SCIMUserQueryResponse;

import org.apache.log4j.Logger;
import org.codehaus.jackson.JsonNode;
import org.codehaus.jackson.map.ObjectMapper;
import org.codehaus.jackson.node.ObjectNode;

import java.io.*;
import java.util.*;

public class privAccountImpl implements SCIMService {

    private static SCIMUserQueryResponse response = new SCIMUserQueryResponse();

    //Static initializer - we only need a common default empty response
    static {
        response.setTotalResults(0);//Static value
        List<SCIMUser> users = new ArrayList<SCIMUser>();
        response.setScimUsers(users);
     }

    private static final Logger LOGGER = Logger.getLogger(privAccountImpl.class);

    /**
     * This method is invoked when a POST is made to /Users with a SCIM payload representing a user
     * to be created.
     * <p/>
     *
     * @param user SCIMUser representation of the SCIM String payload sent by the SCIM client.
     * @return the created SCIMUser.
     * @throws OnPremUserManagementException
     */
    @Override
    public SCIMUser createUser(SCIMUser user) throws OnPremUserManagementException {
		String internalId = createJSONAndCallScript(null, user);
		if (null == internalId)
			internalId = "UNDEFINED";
		user.setId(internalId);
        return user;
    }

    /**
     * This method updates a user.
     * <p/>
     * This method is invoked when a PUT is made to /Users/{id} with the SCIM payload representing a user to
     * be updated.
     * <p/>
     *
     * @param id   the id of the SCIM user.
     * @param user SCIMUser representation of the SCIM String payload sent by the SCIM client.
     * @return the updated SCIMUser.
     * @throws OnPremUserManagementException
     */
    @Override
    public SCIMUser updateUser(String id, SCIMUser user) throws OnPremUserManagementException, EntityNotFoundException {
    	createJSONAndCallScript(id, user);
        return user;
    }

    /**
     * Get all the users.
     * <p/>
     * This method is invoked when a GET is made to /Users
     * In order to support pagination (So that the client and the server are not overwhelmed), this method supports querying based on a start index and the
     * maximum number of results expected by the client. The implementation is responsible for maintaining indices for the SCIM Users.
     *
     * @param pageProperties denotes the pagination properties
     * @param filter         denotes the filter
     * @return the response from the server, which contains a list of  users along with the total number of results, start index and the items per page
     * @throws com.okta.scim.server.exception.OnPremUserManagementException
     *
     */
    @Override
    public SCIMUserQueryResponse getUsers(PaginationProperties pageProperties, SCIMFilter filter) throws OnPremUserManagementException {
       return response;
    }

    /**
     * Get a particular user.
     * <p/>
     * This method is invoked when a GET is made to /Users/{id}
     *
     * @param id the Id of the SCIM User
     * @return the user corresponding to the id
     * @throws com.okta.scim.server.exception.OnPremUserManagementException
     *
     */
    @Override
    public SCIMUser getUser(String id) throws OnPremUserManagementException, EntityNotFoundException {
    	return null;
    }

    @Override
    public SCIMGroup createGroup(SCIMGroup scimg) throws OnPremUserManagementException, DuplicateGroupException {
        throw new UnsupportedOperationException("Not supported yet."); //To change body of generated methods, choose Tools | Templates.
    }

    @Override
    public SCIMGroup updateGroup(String string, SCIMGroup scimg) throws OnPremUserManagementException, EntityNotFoundException {
        throw new UnsupportedOperationException("Not supported yet."); //To change body of generated methods, choose Tools | Templates.
    }

    @Override
    public SCIMGroup getGroup(String string) throws OnPremUserManagementException, EntityNotFoundException {
        throw new UnsupportedOperationException("Not supported yet."); //To change body of generated methods, choose Tools | Templates.
    }

    @Override
    public void deleteGroup(String string) throws OnPremUserManagementException, EntityNotFoundException {
        throw new UnsupportedOperationException("Not supported yet."); //To change body of generated methods, choose Tools | Templates.
    }

    @Override
    public SCIMGroupQueryResponse getGroups(PaginationProperties pp) throws OnPremUserManagementException {
        throw new UnsupportedOperationException("Not supported yet."); //To change body of generated methods, choose Tools | Templates.
    }
	
    @Override
    public UserManagementCapabilities[] getImplementedUserManagementCapabilities() {
        // this method returns the capabilities that the connector can perform

        return new UserManagementCapabilities[]{
            UserManagementCapabilities.PUSH_NEW_USERS,
            UserManagementCapabilities.PUSH_USER_DEACTIVATION,
            UserManagementCapabilities.PUSH_PROFILE_UPDATES,
            UserManagementCapabilities.REACTIVATE_USERS
        };
    }

    private String createJSONAndCallScript(String externalId, SCIMUser user) throws OnPremUserManagementException, EntityNotFoundException {

        String userName = user.getUserName().toLowerCase();
		LOGGER.debug("Called for username : "+userName+", externalId : "+externalId);			
        ObjectMapper mapper = new ObjectMapper();
		Map<String, JsonNode> propertyMap = user.getCustomPropertiesMap();
		Iterator<String> it = propertyMap.keySet().iterator();
		String customPropertiesKey = null;
		if (it.hasNext())
		{
			customPropertiesKey = it.next();
		}
        JsonNode customProperties = user.getCustomPropertiesMap().get(customPropertiesKey);

		String inputFileName = customProperties.get("workingDirectory").asText() + "\\"+userName+System.currentTimeMillis()+"-input.json";
        String scriptName = customProperties.get("powerShellCommandPath").asText();
        JsonNode rootNode = mapper.createObjectNode();
        // if the isActive method returns false then the account should be deactivate
        ((ObjectNode) rootNode).put("operation", externalId==null?"Create":user.isActive()?"Update":"Delete");
        ((ObjectNode) rootNode).put("userName", userName);
        ((ObjectNode) rootNode).put("externalId", externalId);
        ((ObjectNode) rootNode).put("fileName", inputFileName);
        ((ObjectNode) rootNode).put("profile", customProperties);

        try{
        	mapper.writerWithDefaultPrettyPrinter().writeValue(new File(inputFileName), rootNode);
            return triggerPowershell(scriptName, inputFileName);
        }
        catch(Exception e){
        	throw new OnPremUserManagementException("C1000", "user update failed [" + e.getMessage() + "]");
        }
    }

    private String triggerPowershell(String scriptName, String inputFileName) throws OnPremUserManagementException {

        try {
			LOGGER.debug("Making external call : "+"powershell -nologo -noprofile -file "
                    + scriptName + " -path " + inputFileName);
            Process proc = Runtime.getRuntime().exec("powershell -nologo -noprofile -file "
                    + scriptName + " -path " + inputFileName);
            proc.getOutputStream().close();

            String outputFileName = inputFileName.replace("input.json", "output.json");
            
            File outputFile = new File(outputFileName);
            
            // wait for completion 
            proc.waitFor();
            
            if (0 != proc.exitValue())
    			throw new OnPremUserManagementException("C1000", "Error return code from powershell process");
           	
            if (!outputFile.exists())
    			throw new OnPremUserManagementException("C1000", "No output file recieved; expecting - [" + outputFileName + "]");
            
            //Read file in as JSON Node
            //If status is not good, throw OnPremUserManagementException
            ObjectMapper mapper = new ObjectMapper();
            
        	BufferedReader fileReader = new BufferedReader(new FileReader(outputFileName));
        	JsonNode rootNode = mapper.readTree(fileReader);
         
        	JsonNode statusNode = rootNode.path("status");
        	String status = statusNode.getTextValue();
        	if (!status.equalsIgnoreCase("SUCCESS"))
        	{
				String internalCode = rootNode.path("internalCode").getTextValue();
				String details = rootNode.path("details").getTextValue();
        		throw new OnPremUserManagementException(internalCode, details);
        	}
			else{
			   String internalId = null;
			   try{
					internalId = rootNode.path("internalId").getTextValue(); 
			   }
			   catch(Throwable t)
			   {
					//Some issue with reading internalId, however, status is success - we log this and ignore
					LOGGER.debug("Did not get back an internal Id");
			   }
			   return internalId;
			}
            
        } catch (InterruptedException e) {
            // If the function failed then throw an error back to Okta
            LOGGER.error(e.getMessage());
            throw new OnPremUserManagementException("C1000", "triggerPowershell failed [" + e.getMessage() + "]");
        } catch (IOException e) {
            // If the function failed then throw an error back to Okta
            LOGGER.error(e.getMessage());
            throw new OnPremUserManagementException("C1000", "triggerPowershell failed [" + e.getMessage() + "]");
        }
    }
}