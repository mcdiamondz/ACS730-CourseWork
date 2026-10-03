# Lab 2

Instructions for this section will be provided in class and on Blackboard when we reach it.

Put your work for Lab 2 in this folder.


Deployment steps:
	1. created a VPC and a Security Group
	2. added two rules to the security group including openning port 22 and tying it to the workstation IP and open port 80 and allow connection from any IP
	3. got the latest version for the linux image. Created an instance by using the latest image name and assigned it to the created security group
	4. logged into the newly created instance using the default ec2-user
	5. created a new user acs730admin, added it to wheel group, created directories to store the ssh public keys from the workstation where the private key rest
	6. logged in with the newly created user acs730admin and added it to a nopassword group (logged in back with the ec2-user and edited the visudo file to effect the nopassword config)
	7. installed python3
	8. executed the deploy-web.sh script
	9. created systemd script to make the http service persistent on reboot

Difference between systemctl (start/enable):
	systemctl start - puts a deamon(service) in a running state, but dies on system reboot
	systemctl enable - puts the deamon(serivce) in a persistence mode but does not start the serivce, when the service is put in running state it does not die even after restart

Why SSH is restricted to a /32 but HTTP is open to 0.0.0.0/0:
	The /32 means that it is allowing only a single IP address to be specified that can connect to the ssh port
	The 0.0.0.0/0 specifies that any IP address on the internet can connect to the associated port 80

Which user the application runs as, and why that is not root:
	the application runs with the acs730web and it is does not root or belong to a privilage group so if the hosted application ever gets compromised the bad actor cannot have root access to the server.
 
